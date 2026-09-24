"""S09.2 exact, read-only component restore planning."""

import hashlib
from contextlib import contextmanager
from dataclasses import fields, replace

import pytest
from conftest import ready

from larenor_server.core_backups.component_restore import (
    ComponentRestoreAuthorityTarget,
    ComponentRestoreAuthorityVolume,
    ComponentRestorePlanError,
    plan_component_restore,
)
from larenor_server.core_backups.models import MAX_COMPONENT_VOLUME_BYTES
from larenor_server.core_backups.service import (
    BackupCapture,
    ComponentVolumeSnapshot,
    CoreBackupContract,
)


class ComponentBoundary:
    @contextmanager
    def quiesce(self, _deadline):
        common = {
            "serviceId": "jellyfin",
            "serviceVersion": "10.11.11",
            "configSchemaVersion": 1,
            "dataSchemaVersion": "upstream_managed_unverified",
        }
        yield (
            ComponentVolumeSnapshot(
                **common,
                volumeId="jellyfin-config",
                payload=b"restorable config\n",
            ),
            ComponentVolumeSnapshot(
                **common,
                volumeId="jellyfin-cache",
                payload=b"restorable cache\n",
            ),
        )


class Authority:
    def __init__(self, *snapshots):
        self.snapshots = list(snapshots)
        self.calls = 0

    def snapshot(self):
        selected = self.snapshots[min(self.calls, len(self.snapshots) - 1)]
        self.calls += 1
        return selected


def capture(server):
    app, _client, settings, _clock = server
    pair = ready(server)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    contract = CoreBackupContract(
        app.state.core.db,
        app.state.core.auth,
        settings,
        component_boundary=ComponentBoundary(),
    )
    return contract.capture(actor)


def authority_target(**changes):
    volumes = (
        ComponentRestoreAuthorityVolume(
            volume_id="jellyfin-cache",
            binding_id="a" * 64,
            binding_revision=7,
        ),
        ComponentRestoreAuthorityVolume(
            volume_id="jellyfin-config",
            binding_id="b" * 64,
            binding_revision=8,
        ),
    )
    values = {
        "service_id": "jellyfin",
        "installation_id": "c" * 32,
        "service_version": "10.11.11",
        "config_schema_version": 1,
        "data_schema_version": "upstream_managed_unverified",
        "installation_revision": 11,
        "volumes": volumes,
    }
    values.update(changes)
    return ComponentRestoreAuthorityTarget(**values)


def malformed_target(**changes):
    valid = authority_target()
    value = object.__new__(ComponentRestoreAuthorityTarget)
    for item in fields(ComponentRestoreAuthorityTarget):
        object.__setattr__(
            value,
            item.name,
            changes.get(item.name, getattr(valid, item.name)),
        )
    return value


def test_plan_binds_authenticated_snapshot_and_exact_current_target(server):
    opened = capture(server)
    current = (authority_target(),)
    authority = Authority(current)

    plan = plan_component_restore(opened, authority)

    assert plan.snapshot_id == opened.manifest.snapshotId
    assert plan.total_byte_length == sum(
        len(opened.payloads[item])
        for item in opened.manifest.components[0].volumeResourceIds
    )
    assert authority.calls == 2
    assert len(plan.targets) == 1
    target = plan.targets[0]
    assert (
        target.service_id,
        target.installation_id,
        target.service_version,
        target.config_schema_version,
        target.data_schema_version,
        target.installation_revision,
    ) == (
        "jellyfin",
        "c" * 32,
        "10.11.11",
        1,
        "upstream_managed_unverified",
        11,
    )
    assert [item.resource_id for item in target.volumes] == [
        "component-jellyfin-cache",
        "component-jellyfin-config",
    ]
    assert [item.binding_revision for item in target.volumes] == [7, 8]
    for volume in target.volumes:
        payload = opened.payloads[volume.resource_id]
        assert volume.byte_length == len(payload)
        assert volume.sha256 == hashlib.sha256(payload).hexdigest()
    assert repr(plan) == "ComponentRestorePlan(<private>)"
    assert repr(target) == "ComponentRestoreTarget(<private>)"
    assert repr(target.volumes[0]) == "ComponentRestoreVolumeTarget(<private>)"


@pytest.mark.parametrize(
    "case",
    [
        "missing-service",
        "unknown-service",
        "duplicate-service",
        "missing-volume",
        "duplicate-volume",
        "shared-binding",
    ],
)
def test_plan_rejects_unknown_missing_duplicate_or_shared_authority(server, case):
    target = authority_target()
    if case == "missing-service":
        targets = ()
    elif case == "unknown-service":
        targets = (malformed_target(service_id="sonarr"),)
    elif case == "duplicate-service":
        targets = (target, target)
    elif case == "missing-volume":
        targets = (replace(target, volumes=(target.volumes[0],)),)
    elif case == "duplicate-volume":
        targets = (
            malformed_target(volumes=(target.volumes[0], target.volumes[0])),
        )
    else:
        targets = (
            malformed_target(
                volumes=(
                    target.volumes[0],
                    replace(
                        target.volumes[1],
                        binding_id=target.volumes[0].binding_id,
                    ),
                )
            ),
        )
    with pytest.raises(
        ComponentRestorePlanError,
        match="^component_restore_unavailable$",
    ):
        plan_component_restore(capture(server), Authority(targets))


@pytest.mark.parametrize(
    "change",
    [
        {"service_version": "10.11.10"},
        {"config_schema_version": 2},
        {"data_schema_version": "foreign_schema"},
    ],
    ids=["service-version", "config-schema", "data-schema"],
)
def test_plan_rejects_version_or_schema_drift(server, change):
    with pytest.raises(ComponentRestorePlanError):
        plan_component_restore(
            capture(server),
            Authority((authority_target(**change),)),
        )


def test_plan_rejects_authority_drift_and_hides_private_failure(server):
    opened = capture(server)
    initial = (authority_target(),)
    drifted = (replace(authority_target(), installation_revision=12),)
    with pytest.raises(ComponentRestorePlanError) as captured:
        plan_component_restore(opened, Authority(initial, drifted))
    assert str(captured.value) == "component_restore_unavailable"
    assert repr(captured.value) == "ComponentRestorePlanError()"

    class LeakingAuthority:
        def snapshot(self):
            raise RuntimeError("apiKey=secret path=/private/host/volume")

    with pytest.raises(ComponentRestorePlanError) as hidden:
        plan_component_restore(opened, LeakingAuthority())
    assert str(hidden.value) == "component_restore_unavailable"
    assert "secret" not in repr(hidden.value)
    assert "/private/host" not in repr(hidden.value)


def test_plan_rejects_malformed_or_oversize_capture_before_target_publish(server):
    opened = capture(server)
    resource_id = opened.manifest.components[0].volumeResourceIds[0]
    resources = [
        item.model_copy(
            update={"byteLength": MAX_COMPONENT_VOLUME_BYTES + 1}
        )
        if item.id == resource_id
        else item
        for item in opened.manifest.resources
    ]
    malformed = BackupCapture(
        manifest=opened.manifest.model_copy(update={"resources": resources}),
        payloads=opened.payloads,
    )
    authority = Authority((authority_target(),))

    with pytest.raises(ComponentRestorePlanError):
        plan_component_restore(malformed, authority)
    assert authority.calls == 0

    with pytest.raises(ComponentRestorePlanError):
        plan_component_restore(object(), Authority((authority_target(),)))
