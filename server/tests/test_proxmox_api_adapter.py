"""Owned loopback acceptance for the sealed Proxmox API effect adapter."""

from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import socket
import socketserver
import stat
import tempfile
import threading
import time

import pytest

from larenor_server.proxmox_commands.api_adapter import (
    ProxmoxApiAdapterError,
    ProxmoxApiEffectAdapter,
    ProxmoxServiceBinding,
    load_service_binding,
    seal_service_binding,
)
from larenor_server.proxmox_commands.worker_ipc import (
    PackagedProxmoxCommand,
    ProxmoxPowerWorkerClient,
    ProxmoxPowerWorkerServer,
)
from test_proxmox_power_worker_ipc import RunningWorker, descriptor, preview


TOKEN_SECRET = "synthetic-proxmox-token-secret"
RAW_UPID = "UPID:pve:0000002A:0000002B:0000002C:qmstart:101:root@pam:"


@contextmanager
def origin(response):
    requests = []

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            reader = self.request.makefile("rb")
            first = reader.readline()
            if not first:
                return
            headers = []
            while True:
                line = reader.readline()
                if not line:
                    return
                if line == b"\r\n":
                    break
                headers.append(line.decode("latin1").rstrip("\r\n"))
            length = next((int(line.split(":", 1)[1]) for line in headers
                           if line.lower().startswith("content-length:")), 0)
            requests.append((first, headers, reader.read(length)))
            delay, payload = response if isinstance(response, tuple) else (0, response)
            time.sleep(delay)
            try:
                self.request.sendall(payload)
            except OSError:
                pass

    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    with Server(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(
            target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True
        )
        thread.start()
        try:
            yield server.server_address[1], requests
        finally:
            server.shutdown()
            thread.join(1)


def root():
    return tempfile.TemporaryDirectory(
        prefix="lpa-", dir="/private/tmp" if Path("/private/tmp").is_dir() else "/tmp"
    )


def binding(port, **changes):
    values = {
        "schema_version": 1,
        "resource_id": "a" * 32,
        "resource_revision": 5,
        "binding_id": "binding_1",
        "binding_revision": 7,
        "service_id": "service_1",
        "service_revision": 9,
        "scheme": "http",
        "host": "proxmox.fixture",
        "port": port,
        "pinned_address": "127.0.0.1",
        "node": "node-a",
        "guest_kind": "qemu",
        "guest_id": 101,
        "token_id": "larenor@pve!tablet",
        "token_secret": TOKEN_SECRET,
    }
    values.update(changes)
    return ProxmoxServiceBinding(**values)


def command(action="start", **changes):
    values = {
        "request_id": "b" * 32,
        "action": action,
        "resource_id": "a" * 32,
        "user_revision": 3,
        "resource_revision": 5,
        "acl_revision": 6,
        "binding_id": "binding_1",
        "binding_revision": 7,
        "service_id": "service_1",
        "service_revision": 9,
        "guest_kind": "qemu",
        "current_state": "stopped" if action == "start" else "running",
        "status_revision": 11,
        "allowed_addresses": ("127.0.0.1",),
    }
    values.update(changes)
    return PackagedProxmoxCommand(**values)


def loopback(_host, port):
    return [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "",
             ("127.0.0.1", port))]


def seal(root_path, selected):
    key = root_path / "binding.key"
    key.write_bytes(b"k" * 32)
    key.chmod(0o600)
    envelope = root_path / "credential.bin"
    seal_service_binding(envelope, key, selected)
    return envelope, key


def test_binding_is_aes_gcm_sealed_and_permissions_are_fail_closed():
    with root() as name:
        selected = binding(8006)
        envelope, key = seal(Path(name), selected)
        raw = envelope.read_bytes()
        assert stat.S_IMODE(envelope.stat().st_mode) == 0o600
        assert not any(value.encode() in raw for value in (
            TOKEN_SECRET, selected.host, selected.node, selected.token_id,
        ))
        loaded = load_service_binding(envelope, key)
        assert loaded == selected
        assert TOKEN_SECRET not in repr(loaded)

        envelope.chmod(0o640)
        with pytest.raises(ProxmoxApiAdapterError, match="^binding_unavailable$"):
            load_service_binding(envelope, key)
        envelope.chmod(0o600)
        key.write_bytes(b"x" * 32)
        with pytest.raises(ProxmoxApiAdapterError, match="^binding_unavailable$") as raised:
            load_service_binding(envelope, key)
        assert TOKEN_SECRET not in repr(raised.value)


def test_exact_sealed_binding_dispatches_one_fixed_request_and_returns_unknown_upid():
    reply = (
        b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
        + f"Content-Length: {len(json.dumps({'data': RAW_UPID}))}\r\n\r\n".encode()
        + json.dumps({"data": RAW_UPID}).encode()
    )
    with origin(reply) as (port, requests), root() as name:
        envelope, key = seal(Path(name), binding(port))
        adapter = ProxmoxApiEffectAdapter.from_sealed(
            envelope, key, resolver=loopback,
        )
        result = adapter.execute(
            command(), deadline=time.monotonic() + 2, cancelled=lambda: False,
        )
        assert result.outcome == "unknown"
        assert result.state == "stopped" and result.status_revision == 11
        assert result.upid == RAW_UPID
        assert TOKEN_SECRET not in repr(result)
        assert len(requests) == 1
        first, headers, body = requests[0]
        assert first == b"POST /api2/json/nodes/node-a/qemu/101/status/start HTTP/1.1\r\n"
        assert "Host: proxmox.fixture:" + str(port) in headers
        assert "Authorization: PVEAPIToken=larenor@pve!tablet=" + TOKEN_SECRET in headers
        assert body == b""

        with pytest.raises(ProxmoxApiAdapterError):
            adapter.execute(
                command(), deadline=time.monotonic() + 2,
                cancelled=lambda: False,
            )
        assert len(requests) == 1


def test_component_egress_address_must_include_the_sealed_pin_before_dns():
    calls = []
    adapter = ProxmoxApiEffectAdapter(
        binding(8006), resolver=lambda *_args: calls.append("dns"),
    )
    with pytest.raises(ProxmoxApiAdapterError, match="^binding_changed$"):
        adapter.execute(
            command(allowed_addresses=("10.20.30.40",)),
            deadline=time.monotonic() + 1, cancelled=lambda: False,
        )
    assert calls == []


@pytest.mark.parametrize("change", [
    {"resource_id": "c" * 32},
    {"resource_revision": 6},
    {"binding_revision": 8},
    {"service_revision": 10},
    {"guest_kind": "lxc"},
])
def test_exact_resource_guest_and_revisions_are_checked_before_dns(change):
    calls = []
    adapter = ProxmoxApiEffectAdapter(
        binding(8006), resolver=lambda *_args: calls.append("dns"),
    )
    with pytest.raises(ProxmoxApiAdapterError, match="^binding_changed$"):
        adapter.execute(
            command(**change), deadline=time.monotonic() + 1,
            cancelled=lambda: False,
        )
    assert calls == []


def test_dns_pin_peer_and_rebinding_changes_fail_before_secret_send():
    connections = []

    def changed(_host, port):
        return [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "",
                 ("127.0.0.2", port))]

    adapter = ProxmoxApiEffectAdapter(
        binding(8006), resolver=changed,
        connector=lambda *args: connections.append(args),
    )
    result = adapter.execute(
        command(), deadline=time.monotonic() + 1, cancelled=lambda: False,
    )
    assert result.outcome == "unknown"
    assert connections == []


def test_connected_peer_mismatch_rejects_before_authorization_header_is_sent():
    reply = b"HTTP/1.1 500 Error\r\nContent-Length: 0\r\n\r\n"
    with origin(reply) as (port, requests):
        class WrongPeer:
            def __init__(self):
                self.inner = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self.inner.connect(("127.0.0.1", port))

            def settimeout(self, value):
                self.inner.settimeout(value)

            def getpeername(self):
                return ("127.0.0.2", port)

            def sendall(self, value):
                self.inner.sendall(value)

            def recv(self, count):
                return self.inner.recv(count)

            def shutdown(self, how):
                self.inner.shutdown(how)

            def close(self):
                self.inner.close()

        adapter = ProxmoxApiEffectAdapter(
            binding(port), resolver=loopback,
            connector=lambda *_args: WrongPeer(),
        )
        result = adapter.execute(
            command(), deadline=time.monotonic() + 1,
            cancelled=lambda: False,
        )
        assert result.outcome == "unknown"
        wait_for = time.monotonic() + 0.2
        while time.monotonic() < wait_for and not requests:
            time.sleep(0.005)
        assert requests == []


def test_redirect_proxy_large_body_and_deadline_are_unknown_without_retry(monkeypatch):
    trapped = []
    monkeypatch.setenv("HTTP_PROXY", "http://127.0.0.1:9")
    monkeypatch.setenv("HTTPS_PROXY", "http://127.0.0.1:9")
    monkeypatch.setenv("ALL_PROXY", "http://127.0.0.1:9")
    cases = [
        b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9/secret\r\nContent-Length: 0\r\n\r\n",
        b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 9000\r\n\r\n" + b"x" * 9000,
        (0.2, b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n"),
    ]
    for index, response in enumerate(cases):
        with origin(response) as (port, requests):
            adapter = ProxmoxApiEffectAdapter(binding(port), resolver=loopback)
            deadline = time.monotonic() + (0.05 if isinstance(response, tuple) else 1)
            result = adapter.execute(
                command(request_id=(str(index + 1) * 32)),
                deadline=deadline, cancelled=lambda: False,
            )
            assert result.outcome == "unknown"
            assert len(requests) == 1
    assert trapped == []


def test_worker_hashes_accepted_upid_but_never_claims_success_or_retries():
    reply_body = json.dumps({"data": RAW_UPID}).encode()
    reply = (
        b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
        + f"Content-Length: {len(reply_body)}\r\n\r\n".encode() + reply_body
    )
    with origin(reply) as (port, requests), root() as name:
        envelope, key = seal(Path(name), binding(port))
        adapter = ProxmoxApiEffectAdapter.from_sealed(
            envelope, key, resolver=loopback,
        )
        with RunningWorker(adapter) as (_server, client):
            result = client.execute_bounded(
                descriptor(), "start", lambda: None,
                preview=preview(), deadline_ms=2_000,
                allowed_addresses=("127.0.0.1",),
            )
        expected = "UPID-SHA256:" + hashlib.sha256(RAW_UPID.encode()).hexdigest()
        assert result.outcome == "unknown"
        assert result.operation_ref == expected
        assert len(requests) == 1
