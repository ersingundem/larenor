"""S09.2 exact, read-only component restore planning."""

import hashlib
from contextlib import contextmanager
from dataclasses import fields, replace

import pytest
from conftest import ready

from larenor_server.core_backups.component_restore import (
    ComponentRestoreBoundary,
    ComponentRestoreAuthorityTarget,
    ComponentRestoreAuthorityVolume,
    ComponentRestoreCoordinator,
    ComponentRestorePlanError,
    ComponentRestoreRollbackReceipt,
    ComponentRestoreStageReceipt,
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


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


class SyntheticRestoreSession:
    def __init__(self, target, *, fail=None, clock=None):
        self.target = target
        self.fail = fail
        self.clock = clock
        self.events = []
        self.staged = {}
        self.rollback_calls = 0
        self.release_calls = 0

    def quiesce(self, targets, _deadline):
        self.events.append(("quiesce", tuple(item.service_id for item in targets)))
        if self.fail == "quiesce":
            raise RuntimeError("private provider path")
        return True

    def capture_rollback(self, volume, _deadline):
        self.events.append(("snapshot", volume.resource_id))
        if self.fail == "snapshot" and len(self.events) == 3:
            raise RuntimeError("private snapshot failure")
        payload = self.target[volume.resource_id]
        return ComponentRestoreRollbackReceipt(
            resource_id=volume.resource_id,
            binding_id=volume.binding_id,
            binding_revision=volume.binding_revision,
            receipt_id=hashlib.sha256(b"rollback:" + payload).hexdigest(),
            byte_length=len(payload),
            sha256=hashlib.sha256(payload).hexdigest(),
        )

    def stage(self, volume, payload, rollback, _deadline):
        self.events.append(("stage", volume.resource_id))
        if self.fail == "stage" and len(self.staged) == 1:
            raise RuntimeError("private staging failure")
        self.staged[volume.resource_id] = payload
        if self.fail == "deadline" and len(self.staged) == 2:
            self.clock.now = 11.0
        return ComponentRestoreStageReceipt(
            resource_id=volume.resource_id,
            binding_id=volume.binding_id,
            binding_revision=volume.binding_revision,
            rollback_receipt_id=rollback.receipt_id,
            stage_id=hashlib.sha256(b"stage:" + payload).hexdigest(),
            byte_length=len(payload),
            sha256=hashlib.sha256(payload).hexdigest(),
        )

    def revalidate(self, _plan, _deadline):
        self.events.append(("revalidate",))
        return self.fail != "authority"

    def commit(self, stages, rollbacks, _deadline):
        self.events.append(("commit", len(stages), len(rollbacks)))
        self.target.update(self.staged)
        return True

    def rollback(self, rollbacks, stages):
        self.events.append(("rollback", len(rollbacks), len(stages)))
        self.rollback_calls += 1
        self.staged.clear()
        return True

    def release(self):
        self.events.append(("release",))
        self.release_calls += 1
        return True


class SyntheticRestoreBoundary(ComponentRestoreBoundary):
    def __init__(self, session):
        self.session = session
        self.acquire_calls = 0

    def acquire(self, plan, _deadline):
        self.acquire_calls += 1
        self.session.events.append(
            ("acquire", plan.snapshot_id, tuple(
                item.installation_revision for item in plan.targets
            ))
        )
        return self.session


def restore_inputs(server, *, fail=None, clock=None):
    opened = capture(server)
    plan = plan_component_restore(opened, Authority((authority_target(),)))
    target = {
        item.resource_id: b"old:" + item.resource_id.encode()
        for item in plan.targets[0].volumes
    }
    session = SyntheticRestoreSession(target, fail=fail, clock=clock)
    boundary = SyntheticRestoreBoundary(session)
    coordinator = ComponentRestoreCoordinator(boundary, monotonic=clock or (lambda: 0.0))
    return opened, plan, target, session, boundary, coordinator


def test_coordinator_stages_every_volume_then_revalidates_before_one_commit(server):
    opened, plan, target, session, boundary, coordinator = restore_inputs(server)

    receipt = coordinator.restore(opened, plan, deadline=10.0)

    expected_resources = tuple(item.resource_id for item in plan.targets[0].volumes)
    assert boundary.acquire_calls == 1
    assert [event[0] for event in session.events] == [
        "acquire",
        "quiesce",
        "snapshot",
        "snapshot",
        "stage",
        "stage",
        "revalidate",
        "commit",
        "release",
    ]
    assert tuple(event[1] for event in session.events[2:4]) == expected_resources
    assert tuple(event[1] for event in session.events[4:6]) == expected_resources
    assert target == {
        resource_id: opened.payloads[resource_id]
        for resource_id in expected_resources
    }
    assert receipt.snapshot_id == plan.snapshot_id
    assert tuple(item.resource_id for item in receipt.rollbacks) == expected_resources
    assert tuple(item.resource_id for item in receipt.stages) == expected_resources
    assert session.rollback_calls == 0
    assert session.release_calls == 1


@pytest.mark.parametrize(
    "failure",
    ["quiesce", "snapshot", "stage", "authority", "deadline"],
)
def test_coordinator_failure_rolls_back_and_releases_once_without_target_write(
    server, failure
):
    clock = Clock()
    opened, plan, target, session, _boundary, coordinator = restore_inputs(
        server,
        fail=failure,
        clock=clock,
    )
    before = dict(target)

    with pytest.raises(
        ComponentRestorePlanError,
        match="^component_restore_unavailable$",
    ):
        coordinator.restore(opened, plan, deadline=10.0)

    assert target == before
    assert not any(event[0] == "commit" for event in session.events)
    assert session.rollback_calls == 1
    assert session.release_calls == 1
    assert session.events[-2][0] == "rollback"
    assert session.events[-1] == ("release",)
    if failure == "deadline":
        assert session.events[-2] == ("rollback", 2, 2)


def test_default_component_restore_boundary_rejects_without_host_effect(server):
    opened = capture(server)
    plan = plan_component_restore(opened, Authority((authority_target(),)))

    with pytest.raises(
        ComponentRestorePlanError,
        match="^component_restore_unavailable$",
    ):
        ComponentRestoreCoordinator().restore(opened, plan, deadline=10.0)
