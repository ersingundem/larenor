"""Synthetic Unix Engine coverage for the component backup Docker adapter."""

from contextlib import contextmanager
import importlib
import importlib.util
import time

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
        yield authority, receipt, binding


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
    with installed_authority(tmp_path) as (authority, receipt, binding):
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
    with installed_authority(tmp_path) as (authority, receipt, binding):
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
    with installed_authority(tmp_path) as (authority, receipt, binding):
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
    with installed_authority(tmp_path) as (authority, receipt, binding):
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
