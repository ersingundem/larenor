"""Read-only Proxmox power observation stays inside the sealed worker boundary."""

from dataclasses import dataclass
import json
from pathlib import Path
import os
import tempfile
import time

import pytest
from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from larenor_server.proxmox_commands.api_adapter import ProxmoxApiAdapterError
from larenor_server.proxmox_commands.api_adapter import ProxmoxApiEffectAdapter
from larenor_server.proxmox_commands.worker_ipc import (
    PackagedProxmoxObservation,
    PackagedProxmoxObservationResult,
)
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.power_recovery.proxmox_executor import (
    ProxmoxPowerRecoveryExecutor,
)
from larenor_server.proxmox_commands.worker_ipc import ProxmoxPowerWorkerServer
from test_proxmox_api_adapter import binding, loopback, origin, root, seal
from test_proxmox_power_worker_ipc import (
    RunningWorker,
    descriptor,
    write_ready_health,
)
from test_proxmox_resource_adapter import SUMMARY


def observation(**changes):
    values = {
        "request_id": "d" * 32,
        "resource_id": "a" * 32,
        "user_revision": 3,
        "resource_revision": 5,
        "acl_revision": 6,
        "binding_id": "binding_1",
        "binding_revision": 7,
        "service_id": "service_1",
        "service_revision": 9,
        "node": "node-a",
        "guest_kind": "qemu",
        "guest_id": 101,
        "status_revision": 11,
        "allowed_addresses": ("127.0.0.1",),
    }
    values.update(changes)
    return PackagedProxmoxObservation(**values)


@dataclass
class ObservingAdapter:
    observations: list
    effects: list

    def observe(self, command, *, deadline, cancelled):
        assert time.monotonic() < deadline
        assert cancelled() is False
        self.observations.append(command)
        return PackagedProxmoxObservationResult("running", command.status_revision)

    def execute(self, command, *, deadline, cancelled):
        self.effects.append(command)
        raise AssertionError("read-only observation dispatched a mutation")


def test_worker_observation_is_repeatable_read_only_and_keeps_exact_authority():
    adapter = ObservingAdapter([], [])
    with RunningWorker(adapter) as (_server, client):
        first = client.observe_bounded(
            descriptor().__class__(
                **{
                    **descriptor().__dict__,
                    "installation_id": "service_1",
                    "node": "node-a",
                    "guest_id": 101,
                    "capability_ready": True,
                }
            ),
            lambda: None,
            user_revision=3,
            resource_revision=5,
            acl_revision=6,
            deadline_ms=2_000,
            allowed_addresses=("127.0.0.1",),
        )
        second = client.observe_bounded(
            descriptor().__class__(
                **{
                    **descriptor().__dict__,
                    "installation_id": "service_1",
                    "node": "node-a",
                    "guest_id": 101,
                    "capability_ready": True,
                }
            ),
            lambda: None,
            user_revision=3,
            resource_revision=5,
            acl_revision=6,
            deadline_ms=2_000,
            allowed_addresses=("127.0.0.1",),
        )

    assert first == second == PackagedProxmoxObservationResult("running", 11)
    assert len(adapter.observations) == 2
    assert adapter.effects == []
    command = adapter.observations[0]
    assert (
        command.resource_id,
        command.user_revision,
        command.resource_revision,
        command.acl_revision,
    ) == ("a" * 32, 3, 5, 6)
    assert (
        command.binding_id,
        command.binding_revision,
        command.service_id,
        command.service_revision,
    ) == ("binding_1", 7, "service_1", 9)


def test_adapter_observation_only_gets_fixed_current_status_path():
    body = json.dumps({"data": {"status": "running"}}).encode()
    reply = (
        b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
        + f"Content-Length: {len(body)}\r\n\r\n".encode()
        + body
    )
    with origin(reply) as (port, requests), root() as name:
        envelope, key = seal(Path(name), binding(port))
        adapter = ProxmoxApiEffectAdapter.from_sealed(
            envelope,
            key,
            resolver=loopback,
        )
        result = adapter.observe(
            observation(),
            deadline=time.monotonic() + 2,
            cancelled=lambda: False,
        )

    assert result == PackagedProxmoxObservationResult("running", 11)
    assert len(requests) == 1
    first, _headers, body = requests[0]
    assert first == b"GET /api2/json/nodes/node-a/qemu/101/status/current HTTP/1.1\r\n"
    assert body == b""


def test_adapter_rejects_guest_selector_that_differs_from_sealed_binding():
    adapter = ProxmoxApiEffectAdapter(binding(8006), resolver=lambda *_: [])

    with pytest.raises(ProxmoxApiAdapterError, match="^binding_changed$"):
        adapter.observe(
            observation(node="other-node"),
            deadline=time.monotonic() + 2,
            cancelled=lambda: False,
        )


def test_core_constructs_recovery_executor_before_startup_reconciliation(tmp_path):
    adapter = ObservingAdapter([], [])
    socket_root = tempfile.TemporaryDirectory(
        prefix="f18-composition-",
        dir="/private/tmp" if Path("/private/tmp").is_dir() else "/tmp",
    )
    socket_path = Path(socket_root.name) / "power.sock"
    server = ProxmoxPowerWorkerServer(
        socket_path,
        adapter,
        allowed_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(),
        timeout=1,
    )
    server.start()
    try:
        health_path = Path(socket_root.name) / "health.json"
        write_ready_health(health_path, socket_path)
        settings = Settings(
            tmp_path / "data",
            tmp_path / "secrets/vault.key",
            proxmox_power_worker_socket=socket_path,
            proxmox_power_worker_health=health_path,
            proxmox_power_worker_uid=os.getuid(),
        )

        app = create_app(settings)

        assert isinstance(
            app.state.core.power_recovery._executor,
            ProxmoxPowerRecoveryExecutor,
        )
    finally:
        server.close()
        socket_root.cleanup()


def test_core_configures_only_exact_current_resource_binding_and_egress(tmp_path):
    adapter = ObservingAdapter([], [])
    socket_root = tempfile.TemporaryDirectory(
        prefix="f18-policy-",
        dir="/private/tmp" if Path("/private/tmp").is_dir() else "/tmp",
    )
    socket_path = Path(socket_root.name) / "power.sock"
    server = ProxmoxPowerWorkerServer(
        socket_path,
        adapter,
        allowed_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(),
        timeout=1,
    )
    server.start()
    try:
        health_path = Path(socket_root.name) / "health.json"
        write_ready_health(health_path, socket_path)
        clock = Clock()
        settings = Settings(
            tmp_path / "data",
            tmp_path / "secrets/vault.key",
            clock=clock,
            login_ip_limit=100,
            login_account_limit=100,
            login_global_limit=100,
            proxmox_power_worker_socket=socket_path,
            proxmox_power_worker_health=health_path,
            proxmox_power_worker_uid=os.getuid(),
        )
        app = create_app(settings)
        recovery = app.state.core.power_recovery._executor
        recovery.worker.peer_uid = lambda _connection: os.getuid()
        with TestClient(app) as client:
            admin = ready((app, client, settings, clock))
            scope = app.state.core.context
            resource = client.post(
                f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}",
                headers=auth(admin),
                json={"kind": "resource", "label": "Power VM", "order": 0},
            ).json()["record"]
            service = client.post(
                "/api/v1/admin/services",
                headers=auth(admin),
                json={
                    "kind": "proxmox",
                    "name": "Synthetic PVE",
                    "baseUrl": "https://pve.invalid:8006",
                    "credentials": {
                        "token": (
                            "root@pam!larenor="
                            "01234567-89ab-cdef-0123-456789abcdef"
                        )
                    },
                },
            ).json()["service"]
            policy = client.put(
                f"/api/v1/admin/services/{service['id']}/outbound-policy",
                headers=auth(admin),
                json={
                    "expectedRevision": 0,
                    "expectedServiceRevision": 1,
                    "grants": [{
                        "scheme": "https",
                        "host": "pve.invalid",
                        "port": 8006,
                        "addresses": [{
                            "address": "10.20.30.40",
                            "network": "lan",
                        }],
                    }],
                },
            )
            assert policy.status_code == 200, policy.text
            app.state.core.proxmox._reader = lambda _connection, *, guard: (
                guard() or SUMMARY
            )
            resource_id = resource["ref"]["id"]
            base = (
                f"/api/v1/admin/proxmox/{scope.coreId}/{scope.homeId}/"
                f"resources/{resource_id}"
            )
            preview = client.post(
                base + "/binding-preview",
                headers=auth(admin),
                json={
                    "serviceId": service["id"],
                    "expectedServiceRevision": 1,
                    "expectedRevision": 1,
                    "expectedAclRevision": 1,
                    "expectedBindingId": None,
                },
            )
            assert preview.status_code == 201, preview.text
            confirmed = client.post(
                base + "/binding-confirm",
                headers=auth(admin),
                json={"previewId": preview.json()["preview"]["id"]},
            )
            assert confirmed.status_code == 201, confirmed.text
            binding_id = confirmed.json()["binding"]["id"]
            with app.state.core.db.connection() as connection:
                user_revision = connection.execute(
                    "SELECT revision FROM users WHERE id=?",
                    (admin["user"]["id"],),
                ).fetchone()[0]
            provider_ref = {
                "contractVersion": 1,
                "provider": "proxmox",
                "actorId": admin["user"]["id"],
                "actorRevision": user_revision,
                "coreId": scope.coreId,
                "homeId": scope.homeId,
                "resourceId": resource_id,
                "resourceRevision": 1,
                "aclRevision": 1,
                "bindingId": binding_id,
                "bindingRevision": 1,
                "serviceId": service["id"],
                "serviceRevision": 1,
                "egressRevision": 1,
                "installationId": service["id"],
                "node": "pve-a",
                "guestKind": "qemu",
                "guestId": 101,
                "statusRevision": 1,
            }
            from larenor_server.power_recovery.models import ProxmoxPowerProviderRef

            target_id = ProxmoxPowerProviderRef.model_validate(
                provider_ref
            ).target_id()
            configured = client.put(
                "/api/v1/admin/power-recovery/policy",
                headers=auth(admin),
                json={
                    "contractVersion": 1,
                    "expectedRevision": 0,
                    "sourceId": "ups",
                    "sourceToken": "t" * 32,
                    "criticalRuntimeSeconds": 60,
                    "restoreStableSeconds": 30,
                    "targets": [{
                        "targetId": target_id,
                        "label": "Power VM",
                        "kind": "proxmoxGuest",
                        "shutdownOrder": 1,
                        "startOnRestore": True,
                        "timeoutSeconds": 30,
                        "providerRef": provider_ref,
                    }],
                },
            )

            assert configured.status_code == 200, configured.text
            assert len(adapter.observations) == 1
            observed = adapter.observations[0]
            assert (observed.node, observed.guest_kind, observed.guest_id) == (
                "pve-a",
                "qemu",
                101,
            )
    finally:
        server.close()
        socket_root.cleanup()
