"""Core-to-supervised-worker-to-loopback Proxmox acceptance fixture."""

from dataclasses import dataclass, replace
import hashlib
import json
import os
from pathlib import Path
import socket
import socketserver
import tempfile
import threading
import time

import pytest
from fastapi.testclient import TestClient

from conftest import Clock, auth, login, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.proxmox_commands.api_adapter import (
    ProxmoxServiceBinding,
    seal_service_binding,
)
from larenor_server.proxmox_commands.models import ProxmoxGuestDescriptor
from larenor_server.proxmox_commands.worker_runtime import (
    WorkerRuntimeConfig,
    read_health_receipt,
    serve_worker,
)
from larenor_server.proxmox_commands.worker_supervisor import (
    ProxmoxWorkerSupervisor,
    SupervisorConfig,
)


RAW_UPID = "UPID:pve:0000002A:0000002B:0000002C:qmstart:101:root@pam:"
TOKEN = "synthetic-e2e-proxmox-token"


class ApiFixture:
    def __init__(self, apply):
        self.apply = apply
        self.state = "stopped"
        self.requests = []
        fixture = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                reader = self.request.makefile("rb")
                first = reader.readline()
                if not first:
                    return
                headers = []
                while True:
                    line = reader.readline()
                    if not line or line == b"\r\n":
                        break
                    headers.append(line.decode("latin1").rstrip("\r\n"))
                fixture.requests.append((first, headers))
                if first.startswith(b"POST "):
                    if fixture.apply:
                        fixture.state = "running"
                    body = json.dumps({"data": RAW_UPID}).encode()
                else:
                    body = json.dumps({"data": {"status": fixture.state}}).encode()
                response = (
                    b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    + f"Content-Length: {len(body)}\r\n\r\n".encode() + body
                )
                self.request.sendall(response)

        class Server(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True

        self.server = Server(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(
            target=self.server.serve_forever,
            kwargs={"poll_interval": 0.01}, daemon=True,
        )

    @property
    def port(self):
        return self.server.server_address[1]

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_args):
        self.server.shutdown()
        self.thread.join(1)
        self.server.server_close()


@dataclass
class Provider:
    resource_id: str = ""
    fixture: ApiFixture | None = None

    def resolve(self, resource_id):
        if resource_id != self.resource_id or self.fixture is None:
            return None
        state = self.fixture.state
        return ProxmoxGuestDescriptor(
            resource_id, "binding_1", 7, "service_1", 9, "qemu", state,
            2 if state == "running" else 1,
        )


class RuntimeProcess:
    def __init__(self, runtime):
        self.runtime = runtime
        self.stopped = threading.Event()
        self.code = None
        self.thread = threading.Thread(target=self._run)
        self.thread.start()

    def _run(self):
        self.code = serve_worker(
            self.runtime, self.stopped,
            peer_uid=lambda _connection: os.getuid(), timeout=1,
        )

    def poll(self):
        return self.code

    def terminate(self):
        self.stopped.set()

    def kill(self):
        self.stopped.set()

    def wait(self, timeout=None):
        self.thread.join(timeout)
        if self.thread.is_alive():
            import subprocess
            raise subprocess.TimeoutExpired("worker", timeout)
        return self.code


def wait_for(predicate, timeout=2):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    pytest.fail("fixture timeout")


def create_resource(app, client, admin):
    scope = app.state.core.context
    response = client.post(
        f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}",
        headers=auth(admin),
        json={"kind": "resource", "label": "E2E VM", "order": 0},
    )
    assert response.status_code == 201
    return response.json()["record"]


def user_revision(app, user_id):
    with app.state.core.db.connection() as connection:
        return connection.execute(
            "SELECT revision FROM users WHERE id=?", (user_id,)
        ).fetchone()[0]


@pytest.mark.parametrize("confirmed,expected_state", [
    (True, "succeeded"),
    (False, "unknown"),
])
def test_core_supervisor_worker_api_journal_end_to_end(
    tmp_path, confirmed, expected_state,
):
    root = tmp_path.resolve()
    clock = Clock()
    base_settings = Settings(
        root / "data", root / "secrets/vault.key", clock=clock,
        login_ip_limit=100, login_account_limit=100, login_global_limit=100,
    )

    bootstrap = create_app(base_settings)
    with TestClient(bootstrap) as client:
        admin = ready((bootstrap, client, base_settings, clock))
        record = create_resource(bootstrap, client, admin)

    runtime_root = tempfile.TemporaryDirectory(
        prefix="lpe2e-", dir="/private/tmp" if Path("/private/tmp").is_dir() else "/tmp"
    )
    runtime_dir = Path(runtime_root.name)
    key_path = runtime_dir / "binding.key"
    key_path.write_bytes(b"k" * 32)
    key_path.chmod(0o600)
    credential_path = runtime_dir / "credential.bin"
    resource_id = record["ref"]["id"]
    request_id = ("c" if confirmed else "d") * 32

    with ApiFixture(confirmed) as upstream:
        sealed = ProxmoxServiceBinding(
            schema_version=1,
            resource_id=resource_id,
            resource_revision=record["revision"],
            binding_id="binding_1",
            binding_revision=7,
            service_id="service_1",
            service_revision=9,
            scheme="http",
            host="127.0.0.1",
            port=upstream.port,
            pinned_address="127.0.0.1",
            node="node-a",
            guest_kind="qemu",
            guest_id=101,
            token_id="larenor@pve!tablet",
            token_secret=TOKEN,
        )
        seal_service_binding(credential_path, key_path, sealed)
        runtime = WorkerRuntimeConfig(
            runtime_dir / "power.sock", runtime_dir / "health.json",
            credential_path, os.getuid(), key_path,
        )
        supervisor = ProxmoxWorkerSupervisor(
            SupervisorConfig.from_runtime(runtime),
            launch=lambda _command: RuntimeProcess(runtime),
        )
        supervisor_stop = threading.Event()
        supervisor_result = []
        supervisor_thread = threading.Thread(
            target=lambda: supervisor_result.append(supervisor.run(supervisor_stop))
        )
        supervisor_thread.start()
        wait_for(runtime.health_path.exists)
        wait_for(lambda: read_health_receipt(runtime.health_path).state == "ready")

        provider = Provider(resource_id, upstream)
        active_settings = replace(
            base_settings,
            proxmox_power_worker_socket=runtime.socket_path,
            proxmox_power_worker_uid=os.getuid(),
        )
        app = create_app(active_settings, proxmox_guest_provider=provider)
        app.state.core.proxmox_power.executor.peer_uid = lambda _connection: os.getuid()
        with TestClient(app) as client:
            signed = login(
                client, "admin", "Synthetic new password 2026",
            ).json()
            scope = app.state.core.context
            prefix = (
                f"/api/v1/admin/proxmox-power/{scope.coreId}/{scope.homeId}/{resource_id}"
            )
            body = {
                "schemaVersion": 1,
                "requestId": request_id,
                "action": "start",
                "expectedUserRevision": user_revision(app, signed["user"]["id"]),
                "expectedResourceRevision": record["revision"],
                "expectedAclRevision": record["aclRevision"],
                "expectedBindingId": "binding_1",
                "expectedBindingRevision": 7,
                "expectedServiceId": "service_1",
                "expectedServiceRevision": 9,
                "expectedGuestKind": "qemu",
                "expectedCurrentState": "stopped",
                "expectedStatusRevision": 1,
            }
            proposal = client.post(prefix + "/previews", headers=auth(signed), json=body)
            assert proposal.status_code == 201, proposal.text
            completed = client.post(
                prefix + f"/previews/{proposal.json()['preview']['id']}/confirm",
                headers=auth(signed),
                json={
                    "schemaVersion": 1, "requestId": request_id,
                    "highRiskConfirmed": False, "deadlineMs": 5_000,
                },
            )
            assert completed.status_code == 200, completed.text
            receipt = completed.json()["receipt"]
            expected_ref = "UPID-SHA256:" + hashlib.sha256(RAW_UPID.encode()).hexdigest()
            assert receipt["state"] == expected_state
            assert receipt["operationRef"] == expected_ref
            entries = client.get(prefix + "/journal", headers=auth(signed)).json()["entries"]
            assert [entry["state"] for entry in entries[-3:]] == [
                "accepted", "executing", expected_state,
            ]
            assert entries[-1]["operationRef"] == expected_ref
            assert entries[-1]["resourceRevision"] == record["revision"]
            assert entries[-1]["bindingRevision"] == 7
            assert entries[-1]["serviceRevision"] == 9
            public = json.dumps({"receipt": receipt, "entries": entries})
            assert not any(secret in public for secret in (
                TOKEN, "proxmox.fixture", "node-a", "larenor@pve!tablet", RAW_UPID,
            ))
            assert client.post(prefix + "/previews", headers=auth(signed), json=body).status_code == 409
            assert len(upstream.requests) == 2
            assert upstream.requests[0][0] == (
                b"POST /api2/json/nodes/node-a/qemu/101/status/start HTTP/1.1\r\n"
            )
            assert upstream.requests[1][0] == (
                b"GET /api2/json/nodes/node-a/qemu/101/status/current HTTP/1.1\r\n"
            )

        supervisor_stop.set()
        supervisor_thread.join(3)
        assert supervisor_result == [0]
        assert read_health_receipt(runtime.health_path).state == "stopped"

        restarted = create_app(base_settings, proxmox_guest_provider=provider)
        with TestClient(restarted) as client:
            signed = login(
                client, "admin", "Synthetic new password 2026",
            ).json()
            scope = restarted.state.core.context
            prefix = (
                f"/api/v1/admin/proxmox-power/{scope.coreId}/{scope.homeId}/{resource_id}"
            )
            persisted = client.get(
                prefix + "/results/" + request_id, headers=auth(signed),
            )
            assert persisted.status_code == 200
            assert persisted.json()["receipt"]["state"] == expected_state
            assert client.post(prefix + "/previews", headers=auth(signed), json=body).status_code == 409
            assert len(upstream.requests) == 2
    runtime_root.cleanup()
