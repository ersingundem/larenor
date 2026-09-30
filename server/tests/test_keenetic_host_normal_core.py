from contextlib import contextmanager
import json
import os
import socket
import socketserver
import threading
import time

from fastapi.testclient import TestClient

from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.keenetic_commands.credential_lease import (
    KeeneticCredentialLeaseVerifier,
)
from larenor_server.keenetic_commands.rci_adapter import PackagedRciCommandAdapter
from larenor_server.keenetic_commands.rci_transport import (
    LeasedKeeneticRciTransport,
)
from larenor_server.keenetic_commands.worker_runtime import run_worker_once

from conftest import Clock, auth, ready
from test_component_egress import grant_body, policy_url
from test_keenetic_command_provider import snapshot as command_snapshot
from test_keenetic_command_worker_ipc import socket_directory


ROUTER_ADDRESS = "192.168.1.1"
ROUTER_HOST = "router.fixture.test"
ROUTER_PASSWORD = "Synthetic-Keenetic-secret-only"


class _AliasedPeer:
    """Use an owned loopback socket while preserving the production peer pin."""

    def __init__(self, connection, peer):
        self._connection = connection
        self._peer = peer

    def getpeername(self):
        return self._peer

    def __getattr__(self, name):
        return getattr(self._connection, name)


@contextmanager
def _owned_rci_origin(mutation):
    calls = []
    posts = 0

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            nonlocal posts
            reader = self.request.makefile("rb")
            first = reader.readline(8192)
            headers = []
            while (line := reader.readline(8192)) != b"\r\n":
                headers.append(line.decode("latin1").rstrip())
            length = next((
                int(line.split(":", 1)[1])
                for line in headers
                if line.lower().startswith("content-length:")
            ), 0)
            body = reader.read(length)
            authorization_present = any(
                line.lower().startswith("authorization: basic ")
                for line in headers
            )
            calls.append((first, authorization_present, body))
            if first == b"GET /rci/show/version HTTP/1.1\r\n":
                self.request.sendall(
                    b"HTTP/1.1 401 Unauthorized\r\n"
                    b'WWW-Authenticate: Basic realm="Keenetic"\r\n'
                    b"Content-Length: 0\r\n\r\n"
                )
                return
            assert first == b"POST /rci/ HTTP/1.1\r\n"
            assert authorization_present is True
            payload = json.loads(body)
            desired = "up" if posts == 0 else "down"
            assert payload == [
                {"parse": f"interface WifiMaster0/AccessPoint1 {desired}"},
                {"parse": "system configuration save"},
                {"show": {"version": {}}},
                {"show": {"interface": {}}},
            ]
            posts += 1
            # The second operation deliberately receives a plausible RCI
            # response while the authoritative read side remains unchanged.
            if posts == 1:
                mutation.set()
            result = json.dumps([
                {"status": "ok"},
                {"status": "ok"},
                {"version": {"release": "4.3.6", "revision": 44}},
                {"interface": {"WifiMaster0/AccessPoint1": {
                    "id": "WifiMaster0/AccessPoint1",
                    "up": "yes" if desired == "up" else "no",
                    "connected": None,
                    "revision": 71 + posts,
                }}},
            ], separators=(",", ":")).encode("ascii")
            self.request.sendall(
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                + f"Content-Length: {len(result)}\r\n\r\n".encode("ascii")
                + result
            )

    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    with Server(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server.server_address[1], calls
        finally:
            server.shutdown()
            thread.join(2)


def _settings(tmp_path, clock, socket_path, health_path, lease_key):
    return Settings(
        tmp_path / "data",
        tmp_path / "vault.key",
        clock=clock,
        login_ip_limit=100,
        login_account_limit=100,
        login_global_limit=100,
        keenetic_worker_socket=socket_path,
        keenetic_worker_health=health_path,
        keenetic_worker_key_file=lease_key,
        keenetic_worker_uid=os.getuid(),
    )


def _connector(port):
    def connect(_family, expected_peer, timeout):
        connection = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        connection.settimeout(timeout)
        connection.connect(("127.0.0.1", port))
        return _AliasedPeer(connection, expected_peer)

    return connect


def _adapter_factory(key, clock, port):
    def factory(worker_id):
        verifier = KeeneticCredentialLeaseVerifier(
            key,
            worker_id=worker_id,
            clock=clock,
        )
        transport = LeasedKeeneticRciTransport(
            verifier,
            resolver=lambda _host, requested_port: [(
                socket.AF_INET,
                socket.SOCK_STREAM,
                socket.IPPROTO_TCP,
                "",
                (ROUTER_ADDRESS, requested_port),
            )],
            connector=_connector(port),
        )
        return PackagedRciCommandAdapter(transport)

    return factory


def _install_router(client, app, admin, port, mutation):
    context = app.state.core.context
    resources = f"/api/v1/admin/home-resources/{context.coreId}/{context.homeId}"
    resource_response = client.post(
        resources,
        headers=auth(admin),
        json={"kind": "resource", "label": "Owned router fixture", "order": 0},
    )
    assert resource_response.status_code == 201, resource_response.text
    resource = resource_response.json()["record"]
    service_response = client.post(
        "/api/v1/admin/services",
        headers=auth(admin),
        json={
            "kind": "keenetic",
            "name": "Owned RCI fixture",
            "baseUrl": f"http://{ROUTER_HOST}:{port}",
            "credentials": {"username": "fixture", "password": ROUTER_PASSWORD},
        },
    )
    assert service_response.status_code == 201, service_response.text
    service = service_response.json()["service"]
    actor = app.state.core.auth.authenticate(admin["accessToken"])
    service = app.state.core.services.record_verification(
        actor,
        service["id"],
        service["revision"],
        state="authenticated",
        version="4.3.6",
    )["service"]
    policy = grant_body(
        service_revision=service["revision"],
        address=ROUTER_ADDRESS,
        host=ROUTER_HOST,
    )
    policy["grants"][0].update(scheme="http", port=port)
    granted = client.put(policy_url(service), headers=auth(admin), json=policy)
    assert granted.status_code == 200, granted.text

    def read(_connection, guard):
        guard()
        value = command_snapshot()["telemetry"]
        if mutation.is_set():
            value["status"]["statusRevision"] = 72
            for interface in value["interfaces"]:
                if interface["id"] == "WifiMaster0/AccessPoint1":
                    interface["online"] = True
        return value

    app.state.core.keenetic_resources._reader = read
    base = (
        f"/api/v1/admin/keenetic/{context.coreId}/{context.homeId}"
        f"/resources/{resource['ref']['id']}"
    )
    binding_body = {
        "serviceId": service["id"],
        "expectedServiceRevision": service["revision"],
        "expectedResourceRevision": resource["revision"],
        "expectedAclRevision": resource["aclRevision"],
        "expectedBindingId": None,
    }
    preview = client.post(
        base + "/binding-preview",
        headers=auth(admin),
        json=binding_body,
    )
    assert preview.status_code == 201, preview.text
    confirmed = client.post(
        base + "/binding-confirm",
        headers=auth(admin),
        json={"previewId": preview.json()["preview"]["id"]},
    )
    assert confirmed.status_code == 201, confirmed.text
    return resource


def test_normal_core_live_worker_and_owned_tcp_rci_confirm_with_causal_readback(
    tmp_path,
    monkeypatch,
):
    # Darwin lacks Linux SO_PEERCRED; the hosted Linux systemd gate exercises
    # the kernel UID boundary. All AF_UNIX and TCP bytes remain real here.
    monkeypatch.setattr(
        "larenor_server.keenetic_commands.worker_ipc._peer_uid",
        lambda _connection: os.getuid(),
    )
    clock = Clock()
    mutation = threading.Event()
    with _owned_rci_origin(mutation) as (port, calls), socket_directory() as directory:
        socket_path = directory / "runtime.sock"
        health_path = directory / "health.json"
        lease_key = directory / "lease.key"
        key = b"K" * 32
        lease_key.write_bytes(key)
        lease_key.chmod(0o600)
        stopped = threading.Event()
        outcome = []
        worker = threading.Thread(
            target=lambda: outcome.append(run_worker_once(
                socket_path,
                health_path,
                api_uid=os.getuid(),
                socket_gid=None,
                stop=stopped,
                peer_uid=lambda _connection: os.getuid(),
                adapter_factory=_adapter_factory(key, clock, port),
            )),
            daemon=True,
        )
        worker.start()
        try:
            deadline = time.monotonic() + 3
            while not health_path.exists():
                assert worker.is_alive() and time.monotonic() < deadline
                time.sleep(0.01)
            settings = _settings(
                tmp_path,
                clock,
                socket_path,
                health_path,
                lease_key,
            )
            app = create_app(settings)
            with TestClient(app) as client:
                admin = ready((app, client, settings, clock))
                resource = _install_router(client, app, admin, port, mutation)
                ref = resource["ref"]
                commands = (
                    f"/api/v1/admin/homes/{ref['coreId']}/{ref['homeId']}"
                    f"/resources/{ref['id']}/keenetic/commands"
                )
                targets = client.get(commands + "/targets", headers=auth(admin))
                assert targets.status_code == 200, targets.text
                descriptor = next(
                    item
                    for item in targets.json()["descriptors"]
                    if item["target"]["targetKind"] == "guest_wifi"
                )
                body = {
                    "schemaVersion": 1,
                    "action": "guest_wifi_enable",
                    "target": descriptor["target"],
                    "expectedUserRevision": descriptor["expectedUserRevision"],
                    "requestId": "6" * 32,
                    "idempotencyKey": "B" * 43,
                    "reason": "Owned fixture confirmation",
                }
                preview = client.post(
                    commands + "/preview",
                    headers=auth(admin),
                    json=body,
                )
                assert preview.status_code == 200, preview.text
                preview = preview.json()["preview"]
                confirmed = client.post(
                    f"{commands}/{preview['id']}/confirm",
                    headers=auth(admin),
                    json={"token": preview["confirmToken"]},
                )
                assert confirmed.status_code == 200, confirmed.text
                assert confirmed.json()["receipt"]["status"] == "succeeded"
                assert confirmed.json()["receipt"]["transitions"] == [
                    "accepted", "executing", "succeeded",
                ]
                replay = client.post(
                    f"{commands}/{preview['id']}/confirm",
                    headers=auth(admin),
                    json={"token": preview["confirmToken"]},
                )
                assert replay.status_code == 200
                assert replay.json()["receipt"] == confirmed.json()["receipt"]

                current = client.get(commands + "/targets", headers=auth(admin))
                assert current.status_code == 200
                descriptor = next(
                    item
                    for item in current.json()["descriptors"]
                    if item["target"]["targetKind"] == "guest_wifi"
                )
                unchanged_body = {
                    "schemaVersion": 1,
                    "action": "guest_wifi_disable",
                    "target": descriptor["target"],
                    "expectedUserRevision": descriptor["expectedUserRevision"],
                    "requestId": "7" * 32,
                    "idempotencyKey": "C" * 43,
                    "reason": "Owned fixture unchanged-readback proof",
                }
                unchanged_preview = client.post(
                    commands + "/preview",
                    headers=auth(admin),
                    json=unchanged_body,
                )
                assert unchanged_preview.status_code == 200
                unchanged_preview = unchanged_preview.json()["preview"]
                unchanged = client.post(
                    f"{commands}/{unchanged_preview['id']}/confirm",
                    headers=auth(admin),
                    json={"token": unchanged_preview["confirmToken"]},
                )
                assert unchanged.status_code == 200
                assert unchanged.json()["receipt"]["status"] == "unknown"
                assert unchanged.json()["receipt"]["code"] == "keenetic_result_unknown"
                unchanged_replay = client.post(
                    f"{commands}/{unchanged_preview['id']}/confirm",
                    headers=auth(admin),
                    json={"token": unchanged_preview["confirmToken"]},
                )
                assert unchanged_replay.json()["receipt"] == unchanged.json()["receipt"]
                history = client.get(commands + "/history", headers=auth(admin))
                assert history.status_code == 200
                assert ROUTER_PASSWORD not in confirmed.text + history.text
            assert [call[0] for call in calls] == [
                b"GET /rci/show/version HTTP/1.1\r\n",
                b"POST /rci/ HTTP/1.1\r\n",
                b"GET /rci/show/version HTTP/1.1\r\n",
                b"POST /rci/ HTTP/1.1\r\n",
            ]
            assert [call[1] for call in calls] == [False, True, False, True]
        finally:
            stopped.set()
            worker.join(3)
        assert worker.is_alive() is False and outcome == ["stopped"]
