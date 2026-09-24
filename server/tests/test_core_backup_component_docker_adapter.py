"""Synthetic Unix Engine coverage for the component backup Docker adapter."""

import copy
import importlib
import importlib.util
import time
from contextlib import contextmanager

import pytest
from larenor_server.core_backups.component_installation_authority import (
    DurableComponentInstallationAuthority,
)
from larenor_server.plugins.managed_container import ManagedWorkerJournal
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
from test_core_backup_component_installation_authority import (
    install_container,
    ready_volume,
    volume_inputs,
)
from test_engine_http import response
from test_managed_container_binding import snapshot
from test_volume_effects import engine_server
from test_volume_resources import body as volume_body


def api():
    name = "larenor_server.core_backups.component_docker_adapter"
    assert importlib.util.find_spec(name) is not None, (
        "component Docker snapshot adapter is absent"
    )
    return importlib.import_module(name)


@contextmanager
def installed_authority(tmp_path):
    data = volume_inputs()
    selected = tuple(
        item for item in data["plan"].resources if item.serviceId == "jellyfin"
    )
    with (
        ManagedWorkerJournal(tmp_path / "containers", initialize=True) as containers,
        VolumeCreateJournal(tmp_path / "volumes", initialize=True) as volumes,
    ):
        binding = install_container(containers)
        with volumes.locked():
            for resource in selected:
                ready_volume(volumes, data, resource)
        authority = DurableComponentInstallationAuthority(containers, volumes)
        receipt = authority.snapshot()[0]
        yield authority, receipt, binding, volumes


def running_inspect(binding, roots):
    value = snapshot(binding)
    value["State"] = {
        "Status": "running",
        "Running": True,
        "Paused": False,
        "Restarting": False,
        "Dead": False,
    }
    for mount in value["Mounts"]:
        mount["Source"] = str(roots[mount["Name"]])
    return value


def operation_reply(container, receipts):
    by_name = {
        volume.intent.binding.resource.name: volume.intent.binding
        for volume in receipts
    }

    def reply(request, _calls):
        target = request[0].split(" ", 2)[1]
        if target.endswith("/json"):
            return response(container)
        name = target.rsplit("/", 1)[-1]
        assert name in by_name
        return response(volume_body(by_name[name]))

    return reply


def make_roots(tmp_path, binding):
    tmp_path.mkdir()
    roots = {}
    for mount in binding.mounts:
        path = tmp_path / mount.name
        path.mkdir()
        roots[mount.name] = path
    return roots


def test_sources_join_exact_container_mount_volume_receipts_and_host_identity(tmp_path):
    with installed_authority(tmp_path) as (authority, receipt, binding, _volumes):
        roots = make_roots(tmp_path / "payloads", binding)
        container = running_inspect(binding, roots)
        with engine_server(operation_reply(container, receipt.volumes)) as (endpoint, calls):
            adapter = api().UnixDockerComponentSnapshotAdapter(
                endpoint, authority, peer_uid=lambda _: endpoint.owner_uid
            )
            sources = adapter.sources(time.monotonic() + 3)

        assert [item.volume_id for item in sources] == [
            "jellyfin-cache",
            "jellyfin-config",
        ]
        expected = {item.volume_id: item for item in receipt.volumes}
        for source in sources:
            volume = expected[source.volume_id]
            info = source.path.lstat()
            assert source.service_id == receipt.service_id
            assert source.container_id == receipt.container_id
            assert source.path == roots[volume.intent.binding.resource.name]
            assert (source.device, source.inode) == (info.st_dev, info.st_ino)
            assert source.installation_revision == volume.intent.receipt.revision
        assert [call[0] for call in calls] == [
            "GET /version HTTP/1.1",
            f"GET /v1.47/containers/{receipt.container_id}/json HTTP/1.1",
            "GET /version HTTP/1.1",
            "GET /v1.47/volumes/" + receipt.volumes[0].intent.binding.resource.name + " HTTP/1.1",
            "GET /version HTTP/1.1",
            "GET /v1.47/volumes/" + receipt.volumes[1].intent.binding.resource.name + " HTTP/1.1",
        ]
        assert authority.revalidate(sources, time.monotonic() + 1) is True


@pytest.mark.parametrize("damage", ["container", "volume", "target", "source"])
def test_sources_reject_exact_receipt_or_mount_drift_without_private_diagnostics(
    tmp_path, damage
):
    with installed_authority(tmp_path) as (authority, receipt, binding, _volumes):
        roots = make_roots(tmp_path / "private-payloads", binding)
        container = running_inspect(binding, roots)
        volumes = tuple(receipt.volumes)
        if damage == "container":
            container["Id"] = "6" * 64
        elif damage == "target":
            container["Mounts"][0]["Destination"] = "/foreign"
        elif damage == "source":
            container["Mounts"][0]["Source"] = str(tmp_path / "missing-secret")

        reply = operation_reply(container, volumes)
        if damage == "volume":
            good = reply

            def reply(request, calls):
                raw = good(request, calls)
                if "/volumes/" not in request[0]:
                    return raw
                value = volume_body(volumes[0].intent.binding)
                value["Labels"] = dict(value["Labels"])
                value["Labels"]["org.larenor.operation"] = "9" * 32
                return response(value)

        with engine_server(reply) as (endpoint, _calls):
            adapter = api().UnixDockerComponentSnapshotAdapter(
                endpoint, authority, peer_uid=lambda _: endpoint.owner_uid
            )
            with pytest.raises(Exception) as caught:
                adapter.sources(time.monotonic() + 3)

        assert str(caught.value) == "component_engine_unavailable"
        assert "private-payloads" not in repr(caught.value)
        assert "missing-secret" not in repr(caught.value)


def test_sources_reject_shared_device_inode_and_non_directory_sources(tmp_path):
    with installed_authority(tmp_path) as (authority, receipt, binding, _volumes):
        roots = make_roots(tmp_path / "payloads", binding)
        appdata = [
            mount for mount in binding.mounts
            if mount.name in {
                volume.intent.binding.resource.name for volume in receipt.volumes
            }
        ]
        roots[appdata[1].name] = roots[appdata[0].name]
        container = running_inspect(binding, roots)
        with engine_server(operation_reply(container, receipt.volumes)) as (endpoint, _calls):
            adapter = api().UnixDockerComponentSnapshotAdapter(
                endpoint, authority, peer_uid=lambda _: endpoint.owner_uid
            )
            with pytest.raises(Exception, match="^component_engine_unavailable$"):
                adapter.sources(time.monotonic() + 3)

        replacement = tmp_path / "regular-file"
        replacement.write_text("private")
        roots[appdata[1].name] = replacement
        container = running_inspect(binding, roots)
        with engine_server(operation_reply(container, receipt.volumes)) as (endpoint, _calls):
            adapter = api().UnixDockerComponentSnapshotAdapter(
                endpoint, authority, peer_uid=lambda _: endpoint.owner_uid
            )
            with pytest.raises(Exception, match="^component_engine_unavailable$"):
                adapter.sources(time.monotonic() + 3)


def test_sources_reject_paused_restart_state_without_adopting_it(tmp_path):
    with installed_authority(tmp_path) as (authority, receipt, binding, _volumes):
        roots = make_roots(tmp_path / "payloads", binding)
        container = running_inspect(binding, roots)
        container["State"].update({"Status": "paused", "Paused": True})
        with engine_server(operation_reply(container, receipt.volumes)) as (endpoint, calls):
            adapter = api().UnixDockerComponentSnapshotAdapter(
                endpoint, authority, peer_uid=lambda _: endpoint.owner_uid
            )
            with pytest.raises(Exception, match="^component_engine_unavailable$"):
                adapter.sources(time.monotonic() + 3)

        assert not any(" POST " in f" {call[0]} " for call in calls)


def effect_reply(container, receipts, state, *, delays=(), after_effect=None):
    volumes = {
        volume.intent.binding.resource.name: volume.intent.binding
        for volume in receipts
    }

    def reply(request, _calls):
        method, target, _protocol = request[0].split(" ", 2)
        if method == "GET" and target.endswith("/json"):
            value = copy.deepcopy(container)
            value["State"].update({
                "Status": "paused" if state["paused"] else "running",
                "Paused": state["paused"],
            })
            return response(value)
        if method == "GET" and "/volumes/" in target:
            return response(volume_body(volumes[target.rsplit("/", 1)[-1]]))
        assert method == "POST" and request[1] == b""
        action = target.rsplit("/", 1)[-1]
        assert action in {"pause", "unpause"}
        state["paused"] = action == "pause"
        if after_effect is not None:
            after_effect(action)
        if action in delays:
            time.sleep(1.0)
            return None
        return b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"

    return reply


def effect_operations(calls):
    return [
        call[0] for call in calls
        if call[0].startswith("POST /v1.47/containers/")
    ]


def test_pause_and_unpause_use_one_effect_each_with_fresh_state_reconciliation(
    tmp_path,
):
    with installed_authority(tmp_path) as (
        authority, receipt, binding, _volumes,
    ):
        roots = make_roots(tmp_path / "payloads", binding)
        container = running_inspect(binding, roots)
        state = {"paused": False}
        reply = effect_reply(container, receipt.volumes, state)
        with engine_server(reply) as (endpoint, calls):
            adapter = api().UnixDockerComponentSnapshotAdapter(
                endpoint,
                authority,
                peer_uid=lambda _: endpoint.owner_uid,
                effect_seconds=4.0,
            )
            adapter.sources(time.monotonic() + 5)
            assert adapter.pause(receipt.container_id, time.monotonic() + 12) is True
            assert state["paused"] is True
            assert adapter.unpause(receipt.container_id, time.monotonic() + 12) is True
            assert state["paused"] is False

        assert effect_operations(calls) == [
            f"POST /v1.47/containers/{receipt.container_id}/pause HTTP/1.1",
            f"POST /v1.47/containers/{receipt.container_id}/unpause HTTP/1.1",
        ]


def test_timeout_after_effect_reconciles_by_get_without_replaying_post(tmp_path):
    with installed_authority(tmp_path) as (
        authority, receipt, binding, _volumes,
    ):
        roots = make_roots(tmp_path / "payloads", binding)
        container = running_inspect(binding, roots)
        state = {"paused": False}
        reply = effect_reply(
            container,
            receipt.volumes,
            state,
            delays={"pause", "unpause"},
        )
        with engine_server(reply, request_timeout=1) as (endpoint, calls):
            adapter = api().UnixDockerComponentSnapshotAdapter(
                endpoint,
                authority,
                peer_uid=lambda _: endpoint.owner_uid,
                effect_seconds=0.75,
            )
            adapter.sources(time.monotonic() + 8)
            assert adapter.pause(receipt.container_id, time.monotonic() + 8) is True
            assert adapter.unpause(receipt.container_id, time.monotonic() + 8) is True

        operations = effect_operations(calls)
        assert len(operations) == 2
        assert sum("/pause " in item for item in operations) == 1
    assert sum("/unpause " in item for item in operations) == 1


def test_ambiguous_pause_never_replays_and_cleanup_waits_for_late_effect(
    tmp_path,
):
    with installed_authority(tmp_path) as (
        authority, receipt, binding, _volumes,
    ):
        roots = make_roots(tmp_path / "payloads", binding)
        container = running_inspect(binding, roots)
        state = {"paused": False}
        ordinary = effect_reply(container, receipt.volumes, state)

        def reply(request, calls):
            if request[0].startswith("POST ") and "/pause " in request[0]:
                time.sleep(5.0)
                return None
            return ordinary(request, calls)

        with engine_server(reply, request_timeout=1) as (endpoint, calls):
            adapter = api().UnixDockerComponentSnapshotAdapter(
                endpoint, authority,
                peer_uid=lambda _: endpoint.owner_uid,
                effect_seconds=4.0,
            )
            adapter.sources(time.monotonic() + 5)
            with pytest.raises(Exception, match="^component_engine_unavailable$"):
                adapter.pause(receipt.container_id, time.monotonic() + 12)
            with pytest.raises(Exception, match="^component_engine_unavailable$"):
                adapter.pause(receipt.container_id, time.monotonic() + 12)
            with pytest.raises(Exception, match="^component_engine_unavailable$"):
                adapter.unpause(receipt.container_id, time.monotonic() + 12)
            state["paused"] = True
            assert adapter.unpause(
                receipt.container_id, time.monotonic() + 12) is True

        operations = effect_operations(calls)
        assert sum("/pause " in item for item in operations) == 1
        assert sum("/unpause " in item for item in operations) == 1


def test_ambiguous_unpause_never_replays_post(tmp_path):
    with installed_authority(tmp_path) as (
        authority, receipt, binding, _volumes,
    ):
        roots = make_roots(tmp_path / "payloads", binding)
        container = running_inspect(binding, roots)
        state = {"paused": False}
        ordinary = effect_reply(container, receipt.volumes, state)

        def reply(request, calls):
            if request[0].startswith("POST ") and "/unpause " in request[0]:
                time.sleep(5.0)
                return None
            return ordinary(request, calls)

        with engine_server(reply, request_timeout=1) as (endpoint, calls):
            adapter = api().UnixDockerComponentSnapshotAdapter(
                endpoint, authority,
                peer_uid=lambda _: endpoint.owner_uid,
                effect_seconds=4.0,
            )
            adapter.sources(time.monotonic() + 5)
            assert adapter.pause(
                receipt.container_id, time.monotonic() + 12) is True
            with pytest.raises(Exception, match="^component_engine_unavailable$"):
                adapter.unpause(receipt.container_id, time.monotonic() + 12)
            with pytest.raises(Exception, match="^component_engine_unavailable$"):
                adapter.unpause(receipt.container_id, time.monotonic() + 12)

        operations = effect_operations(calls)
        assert sum("/pause " in item for item in operations) == 1
        assert sum("/unpause " in item for item in operations) == 1


def test_authority_drift_before_pause_denies_dispatch(tmp_path):
    with installed_authority(tmp_path) as (
        authority, receipt, binding, volumes,
    ):
        roots = make_roots(tmp_path / "payloads", binding)
        container = running_inspect(binding, roots)
        state = {"paused": False}
        with engine_server(
            effect_reply(container, receipt.volumes, state)
        ) as (endpoint, calls):
            adapter = api().UnixDockerComponentSnapshotAdapter(
                endpoint, authority, peer_uid=lambda _: endpoint.owner_uid
            )
            adapter.sources(time.monotonic() + 5)
            volumes._db.execute(
                "UPDATE resources SET revision=revision+1 WHERE resource_id="
                "(SELECT resource_id FROM resources ORDER BY resource_id LIMIT 1)"
            )
            with pytest.raises(Exception, match="^component_engine_unavailable$"):
                adapter.pause(receipt.container_id, time.monotonic() + 5)

        assert effect_operations(calls) == []
        assert state["paused"] is False


def test_authority_drift_after_pause_does_not_publish_success_or_replay(tmp_path):
    with installed_authority(tmp_path) as (
        authority, receipt, binding, volumes,
    ):
        roots = make_roots(tmp_path / "payloads", binding)
        container = running_inspect(binding, roots)
        state = {"paused": False}
        drifted = {"value": False}

        def drift(action):
            if action == "pause" and not drifted["value"]:
                drifted["value"] = True
                volumes._db.execute(
                    "UPDATE resources SET revision=revision+1 WHERE resource_id="
                    "(SELECT resource_id FROM resources ORDER BY resource_id LIMIT 1)"
                )

        with engine_server(
            effect_reply(
                container, receipt.volumes, state, after_effect=drift
            )
        ) as (endpoint, calls):
            adapter = api().UnixDockerComponentSnapshotAdapter(
                endpoint, authority, peer_uid=lambda _: endpoint.owner_uid
            )
            adapter.sources(time.monotonic() + 5)
            with pytest.raises(Exception, match="^component_engine_unavailable$"):
                adapter.pause(receipt.container_id, time.monotonic() + 5)

        assert state["paused"] is True
        assert effect_operations(calls) == [
            f"POST /v1.47/containers/{receipt.container_id}/pause HTTP/1.1"
        ]


def test_new_adapter_never_unpauses_an_initially_paused_container(tmp_path):
    with installed_authority(tmp_path) as (
        authority, receipt, binding, _volumes,
    ):
        roots = make_roots(tmp_path / "payloads", binding)
        container = running_inspect(binding, roots)
        state = {"paused": True}
        with engine_server(
            effect_reply(container, receipt.volumes, state)
        ) as (endpoint, calls):
            restarted = api().UnixDockerComponentSnapshotAdapter(
                endpoint, authority, peer_uid=lambda _: endpoint.owner_uid
            )
            with pytest.raises(Exception, match="^component_engine_unavailable$"):
                restarted.sources(time.monotonic() + 5)
            with pytest.raises(Exception, match="^component_engine_unavailable$"):
                restarted.unpause(receipt.container_id, time.monotonic() + 5)

        assert state["paused"] is True
        assert effect_operations(calls) == []


def test_authenticated_restore_recovery_adopts_exact_paused_container(tmp_path):
    with installed_authority(tmp_path) as (
        authority, receipt, binding, _volumes,
    ):
        roots = make_roots(tmp_path / "payloads", binding)
        container = running_inspect(binding, roots)
        state = {"paused": True}
        with engine_server(
            effect_reply(container, receipt.volumes, state)
        ) as (endpoint, calls):
            restarted = api().UnixDockerComponentSnapshotAdapter(
                endpoint, authority, peer_uid=lambda _: endpoint.owner_uid
            )
            sources, paused = restarted.restore_sources(time.monotonic() + 5)

            assert sources
            assert paused == (receipt.container_id,)
            assert restarted.adopt_restore_pauses(
                paused, time.monotonic() + 5
            ) is True
            assert restarted.unpause(
                receipt.container_id, time.monotonic() + 5
            ) is True

        assert state["paused"] is False
        assert effect_operations(calls) == [
            f"POST /v1.47/containers/{receipt.container_id}/unpause HTTP/1.1"
        ]
