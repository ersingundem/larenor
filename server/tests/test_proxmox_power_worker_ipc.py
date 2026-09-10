"""Owned local fixture for the private Proxmox power-effect worker boundary."""

from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import socket
import tempfile
import time

import pytest
from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.proxmox_commands.models import (
    PreviewRequest,
    ProxmoxGuestDescriptor,
)
from larenor_server.proxmox_commands.worker_ipc import (
    PackagedProxmoxApiResult,
    ProxmoxPowerWorkerClient,
    ProxmoxPowerWorkerError,
    ProxmoxPowerWorkerServer,
    verified_power_worker_client,
)


RAW_UPID = "UPID:pve:0000002A:0000002B:0000002C:qmstart:101:root@pam:"


def descriptor():
    return ProxmoxGuestDescriptor(
        resource_id="a" * 32,
        binding_id="binding_1",
        binding_revision=7,
        service_id="service_1",
        service_revision=9,
        guest_kind="qemu",
        status="stopped",
        status_revision=11,
    )


def preview(action="start"):
    return PreviewRequest(
        schemaVersion=1,
        requestId="b" * 32,
        action=action,
        expectedUserRevision=3,
        expectedResourceRevision=5,
        expectedAclRevision=6,
        expectedBindingId="binding_1",
        expectedBindingRevision=7,
        expectedServiceId="service_1",
        expectedServiceRevision=9,
        expectedGuestKind="qemu",
        expectedCurrentState="stopped" if action == "start" else "running",
        expectedStatusRevision=11,
    )


@dataclass
class Adapter:
    calls: list

    def execute(self, command, *, deadline, cancelled):
        assert time.monotonic() < deadline
        assert cancelled() is False
        self.calls.append(command)
        target = {
            "start": "running", "shutdown": "stopped", "stop": "stopped",
            "reboot": "running", "reset": "running",
        }[command.action]
        return PackagedProxmoxApiResult(
            outcome="succeeded",
            state=target,
            status_revision=12,
            upid=RAW_UPID,
        )


class RunningWorker:
    def __init__(self, adapter, *, timeout=0.5, client_uid=None, server_uid=None):
        self.adapter = adapter
        self.timeout = timeout
        self.client_uid = os.getuid() if client_uid is None else client_uid
        self.server_uid = os.getuid() if server_uid is None else server_uid
        self.temp = None
        self.server = None

    def __enter__(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="lpw-", dir="/private/tmp" if Path("/private/tmp").is_dir() else "/tmp"
        )
        path = Path(self.temp.name) / "worker.sock"
        self.server = ProxmoxPowerWorkerServer(
            path,
            self.adapter,
            allowed_uid=self.client_uid,
            peer_uid=lambda _connection: self.client_uid,
            timeout=self.timeout,
        )
        self.server.start()
        client = ProxmoxPowerWorkerClient(
            path,
            owner_uid=self.server_uid,
            peer_uid=lambda _connection: self.server_uid,
            timeout=self.timeout,
        )
        return self.server, client

    def __exit__(self, *_args):
        if self.server is not None:
            self.server.close()
        if self.temp is not None:
            self.temp.cleanup()


def test_worker_receives_exact_preview_revisions_and_only_returns_hashed_upid():
    adapter = Adapter([])
    with RunningWorker(adapter) as (_server, client):
        result = client.execute_bounded(
            descriptor(), "start", lambda: None,
            preview=preview(), deadline_ms=2_000,
        )

    assert len(adapter.calls) == 1
    command = adapter.calls[0]
    assert command.request_id == "b" * 32
    assert command.action == "start"
    assert command.resource_id == "a" * 32
    assert (command.user_revision, command.resource_revision, command.acl_revision) == (3, 5, 6)
    assert (command.binding_id, command.binding_revision) == ("binding_1", 7)
    assert (command.service_id, command.service_revision) == ("service_1", 9)
    assert (command.guest_kind, command.current_state, command.status_revision) == ("qemu", "stopped", 11)
    expected = "UPID-SHA256:" + hashlib.sha256(RAW_UPID.encode("utf-8")).hexdigest()
    assert result.operation_ref == expected
    assert RAW_UPID not in repr(result)
    assert RAW_UPID not in repr(command)


@pytest.mark.parametrize("action,state", [
    ("start", "stopped"),
    ("shutdown", "running"),
    ("stop", "running"),
    ("reboot", "running"),
    ("reset", "running"),
])
def test_worker_has_a_fixed_five_action_allowlist(action, state):
    adapter = Adapter([])
    selected = descriptor()
    selected = ProxmoxGuestDescriptor(
        selected.resource_id, selected.binding_id, selected.binding_revision,
        selected.service_id, selected.service_revision, selected.guest_kind,
        state, selected.status_revision,
    )
    body = preview(action)
    with RunningWorker(adapter) as (_server, client):
        result = client.execute_bounded(
            selected, action, lambda: None, preview=body, deadline_ms=2_000,
        )
    assert result.outcome == "succeeded"
    assert len(adapter.calls) == 1


@pytest.mark.parametrize("action", ["suspend", "resume", "migrate", "shell"])
def test_worker_rejects_actions_outside_fixed_effect_allowlist(action):
    adapter = Adapter([])
    with RunningWorker(adapter) as (_server, client):
        with pytest.raises(ProxmoxPowerWorkerError, match="^worker_unavailable$"):
            client.execute_bounded(
                descriptor(), action, lambda: None,
                preview=preview("start"), deadline_ms=2_000,
            )
    assert adapter.calls == []


def test_private_socket_owner_peer_and_mode_are_checked_before_effect():
    adapter = Adapter([])
    with RunningWorker(adapter) as (server, client):
        os.chmod(server.path, 0o666)
        with pytest.raises(ProxmoxPowerWorkerError):
            client.execute_bounded(
                descriptor(), "start", lambda: None,
                preview=preview(), deadline_ms=2_000,
            )
    assert adapter.calls == []

    with RunningWorker(adapter, server_uid=os.getuid() + 1) as (_server, client):
        with pytest.raises(ProxmoxPowerWorkerError):
            client.execute_bounded(
                descriptor(), "start", lambda: None,
                preview=preview(), deadline_ms=2_000,
            )
    assert adapter.calls == []


def test_guard_and_deadline_cancel_without_retry_or_late_success():
    adapter = Adapter([])
    guard_calls = 0

    def cancelled():
        nonlocal guard_calls
        guard_calls += 1
        raise ConnectionError("private disconnect detail")

    with RunningWorker(adapter, timeout=0.25) as (_server, client):
        with pytest.raises(ProxmoxPowerWorkerError, match="^worker_unavailable$") as raised:
            client.execute_bounded(
                descriptor(), "start", cancelled,
                preview=preview(), deadline_ms=500,
            )
    assert guard_calls == 1
    assert adapter.calls == []
    assert "private disconnect detail" not in repr(raised.value)


def test_duplicate_request_is_not_replayed():
    adapter = Adapter([])
    with RunningWorker(adapter) as (_server, client):
        first = client.execute_bounded(
            descriptor(), "start", lambda: None,
            preview=preview(), deadline_ms=2_000,
        )
        with pytest.raises(ProxmoxPowerWorkerError):
            client.execute_bounded(
                descriptor(), "start", lambda: None,
                preview=preview(), deadline_ms=2_000,
            )
    assert first.outcome == "succeeded"
    assert len(adapter.calls) == 1


def test_worker_never_opens_inet_sockets(monkeypatch):
    adapter = Adapter([])
    real_socket = socket.socket

    def local_only(family=socket.AF_INET, *args, **kwargs):
        if family in (socket.AF_INET, socket.AF_INET6):
            pytest.fail("live network forbidden")
        return real_socket(family, *args, **kwargs)

    monkeypatch.setattr(socket, "socket", local_only)
    with RunningWorker(adapter) as (_server, client):
        assert client.execute_bounded(
            descriptor(), "start", lambda: None,
            preview=preview(), deadline_ms=2_000,
        ).outcome == "succeeded"


def test_core_uses_explicit_worker_and_journal_contains_only_upid_hash(tmp_path):
    class Provider:
        value = None

        def resolve(self, resource_id):
            return self.value if self.value is not None and self.value.resource_id == resource_id else None

    class UpdatingAdapter:
        calls = 0

        def execute(self, command, *, deadline, cancelled):
            assert time.monotonic() < deadline
            assert cancelled() is False
            self.calls += 1
            provider.value = ProxmoxGuestDescriptor(
                command.resource_id, command.binding_id, command.binding_revision,
                command.service_id, command.service_revision, command.guest_kind,
                "running", command.status_revision + 1,
            )
            return PackagedProxmoxApiResult(
                "succeeded", "running", command.status_revision + 1, RAW_UPID
            )

    provider = Provider()
    adapter = UpdatingAdapter()
    root = tmp_path.resolve()
    socket_temp = tempfile.TemporaryDirectory(
        prefix="lpw-core-", dir="/private/tmp" if Path("/private/tmp").is_dir() else "/tmp"
    )
    socket_path = Path(socket_temp.name) / "power.sock"
    worker = ProxmoxPowerWorkerServer(
        socket_path, adapter, allowed_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(), timeout=1,
    )
    worker.start()
    try:
        clock = Clock()
        settings = Settings(
            root / "data", root / "secrets/vault.key", clock=clock,
            login_ip_limit=100, login_account_limit=100, login_global_limit=100,
            proxmox_power_worker_socket=socket_path,
            proxmox_power_worker_uid=os.getuid(),
        )
        app = create_app(settings, proxmox_guest_provider=provider)
        # The fixture substitutes peer-UID observation only inside the worker;
        # macOS has no Linux SO_PEERCRED, so bind the owned test observer here.
        app.state.core.proxmox_power.executor.peer_uid = lambda _connection: os.getuid()
        with TestClient(app) as client:
            admin = ready((app, client, settings, clock))
            scope = app.state.core.context
            created = client.post(
                f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}",
                headers=auth(admin),
                json={"kind": "resource", "label": "Synthetic VM", "order": 0},
            ).json()["record"]
            resource_id = created["ref"]["id"]
            provider.value = ProxmoxGuestDescriptor(
                resource_id, "binding_1", 7, "service_1", 9,
                "qemu", "stopped", 11,
            )
            with app.state.core.db.connection() as connection:
                user_revision = connection.execute(
                    "SELECT revision FROM users WHERE id=?", (admin["user"]["id"],)
                ).fetchone()[0]
            prefix = (
                f"/api/v1/admin/proxmox-power/{scope.coreId}/{scope.homeId}/{resource_id}"
            )
            body = {
                "schemaVersion": 1, "requestId": "b" * 32, "action": "start",
                "expectedUserRevision": user_revision,
                "expectedResourceRevision": created["revision"],
                "expectedAclRevision": created["aclRevision"],
                "expectedBindingId": "binding_1", "expectedBindingRevision": 7,
                "expectedServiceId": "service_1", "expectedServiceRevision": 9,
                "expectedGuestKind": "qemu", "expectedCurrentState": "stopped",
                "expectedStatusRevision": 11,
            }
            proposal = client.post(prefix + "/previews", headers=auth(admin), json=body)
            assert proposal.status_code == 201, proposal.text
            completed = client.post(
                prefix + f"/previews/{proposal.json()['preview']['id']}/confirm",
                headers=auth(admin),
                json={
                    "schemaVersion": 1, "requestId": "b" * 32,
                    "highRiskConfirmed": False, "deadlineMs": 2_000,
                },
            )
            assert completed.status_code == 200, completed.text
            receipt = completed.json()["receipt"]
            expected = "UPID-SHA256:" + hashlib.sha256(RAW_UPID.encode()).hexdigest()
            assert receipt["state"] == "succeeded"
            assert receipt["operationRef"] == expected
            events = client.get(prefix + "/journal", headers=auth(admin)).json()["entries"]
            assert events[-1]["operationRef"] == expected
            assert RAW_UPID not in str(events)
        assert RAW_UPID.encode() not in settings.database_file.read_bytes()
        assert adapter.calls == 1
    finally:
        worker.close()
        socket_temp.cleanup()


def test_default_core_does_not_construct_or_contact_a_power_worker(tmp_path, monkeypatch):
    root = tmp_path.resolve()
    settings = Settings(root / "data", root / "secrets/vault.key")
    real_socket = socket.socket

    def no_socket(*args, **kwargs):
        pytest.fail("default production effect opened a socket")

    monkeypatch.setattr(socket, "socket", no_socket)
    app = create_app(settings)
    assert app.state.core.proxmox_power.executor.__class__.__name__ == "UnavailablePowerExecutor"
    monkeypatch.setattr(socket, "socket", real_socket)


def test_worker_configuration_is_explicit_absolute_and_uid_private(monkeypatch, tmp_path):
    path = (tmp_path / "power.sock").resolve()
    monkeypatch.setenv("LARENOR_DATA_DIR", str((tmp_path / "data").resolve()))
    monkeypatch.setenv("LARENOR_KEY_FILE", str((tmp_path / "key").resolve()))
    monkeypatch.setenv("LARENOR_PROXMOX_POWER_WORKER_SOCKET", str(path))
    monkeypatch.setenv("LARENOR_PROXMOX_POWER_WORKER_UID", str(os.getuid()))
    settings = Settings.from_environment()
    assert settings.proxmox_power_worker_socket == path
    assert settings.proxmox_power_worker_uid == os.getuid()
    with pytest.raises(ValueError, match="^invalid_worker_configuration$"):
        Settings(
            tmp_path / "data", tmp_path / "key",
            proxmox_power_worker_socket=Path("relative.sock"),
        )


def test_core_worker_health_binds_the_original_socket_inode(tmp_path):
    socket_root = tempfile.TemporaryDirectory(
        prefix="lpw-health-",
        dir="/private/tmp" if Path("/private/tmp").is_dir() else "/tmp",
    )
    root = Path(socket_root.name)
    socket_path = root / "power.sock"
    health_path = root / "power-health.json"
    original = ProxmoxPowerWorkerServer(
        socket_path,
        Adapter([]),
        allowed_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(),
        timeout=1,
    )
    original.start()
    try:
        info = socket_path.lstat()
        health_path.write_text(json.dumps({
            "schemaVersion": 1,
            "capability": "proxmox-power-effect",
            "state": "ready",
            "workerId": "c" * 32,
            "workerUid": os.getuid(),
            "socketDevice": info.st_dev,
            "socketInode": info.st_ino,
            "emittedAt": time.time(),
        }))
        health_path.chmod(0o600)
        client = verified_power_worker_client(
            socket_path, health_path, os.getuid(),
            peer_uid=lambda _connection: os.getuid(),
            timeout=1,
        )
        assert isinstance(client, ProxmoxPowerWorkerClient)
        original.close()

        replacement_calls = []
        replacement = ProxmoxPowerWorkerServer(
            socket_path,
            Adapter(replacement_calls),
            allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(),
            timeout=1,
        )
        replacement.start()
        try:
            with pytest.raises(ProxmoxPowerWorkerError, match="^worker_unavailable$"):
                client.execute_bounded(
                    descriptor(), "start", lambda: None,
                    preview=preview(), deadline_ms=1_000,
                )
            assert replacement_calls == []
        finally:
            replacement.close()
    finally:
        original.close()
        socket_root.cleanup()


def test_core_worker_health_configuration_is_all_or_nothing(tmp_path):
    root = tmp_path.resolve()
    socket_path = (root / "power.sock").resolve()
    health_path = (root / "power-health.json").resolve()
    with pytest.raises(ValueError, match="^invalid_worker_configuration$"):
        Settings(
            root / "data", root / "key",
            proxmox_power_worker_socket=socket_path,
            proxmox_power_worker_uid=os.getuid(),
        )
    with pytest.raises(ValueError, match="^invalid_worker_configuration$"):
        Settings(
            root / "data", root / "key",
            proxmox_power_worker_health=health_path,
            proxmox_power_worker_uid=os.getuid(),
        )
