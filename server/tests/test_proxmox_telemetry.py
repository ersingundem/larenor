"""Owned loopback contract for bounded Proxmox telemetry observation."""

from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import socket
import socketserver
import threading
import time

import pytest

from larenor_server.proxmox_commands.api_adapter import (
    ProxmoxServiceBinding,
    seal_service_binding,
)
from larenor_server.proxmox_commands.telemetry import (
    CredentialLeaseError,
    ProxmoxTelemetryObserver,
    ServiceCredentialLeaseIssuer,
    TelemetryExpectation,
)


TOKEN = "synthetic-observer-token"
RAW_UPID = "UPID:pve:0000002A:0000002B:0000002C:qmstart:101:root@pam:"


def expectation(**changes):
    values = {
        "resource_id": "a" * 32,
        "resource_revision": 5,
        "binding_id": "binding_1",
        "binding_revision": 7,
        "service_id": "service_1",
        "service_revision": 9,
        "node": "node-a",
        "node_revision": 11,
        "guest_revisions": (("qemu", 101, 21), ("lxc", 202, 31)),
    }
    values.update(changes)
    return TelemetryExpectation(**values)


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
        "token_secret": TOKEN,
    }
    values.update(changes)
    return ProxmoxServiceBinding(**values)


def responses(**changes):
    values = {
        "/api2/json/nodes/node-a/status": {
            "data": {
                "revision": 11, "cpu": 0.25, "maxcpu": 8,
                "mem": 4_000, "maxmem": 16_000,
                "rootfs": 20_000, "maxrootfs": 100_000,
                "netin": 1_000, "netout": 2_000, "uptime": 3_600,
            }
        },
        "/api2/json/nodes/node-a/qemu": {"data": [{
            "vmid": 101, "revision": 21, "name": "core-vm",
            "status": "running", "cpu": 0.5, "maxcpu": 4,
            "mem": 2_000, "maxmem": 8_000, "disk": 5_000,
            "maxdisk": 50_000, "netin": 300, "netout": 400,
            "uptime": 1_800,
        }]},
        "/api2/json/nodes/node-a/lxc": {"data": [{
            "vmid": 202, "revision": 31, "name": "media-ct",
            "status": "stopped", "cpu": 0.0, "maxcpu": 2,
            "mem": 0, "maxmem": 4_000, "disk": 10_000,
            "maxdisk": 40_000, "netin": 500, "netout": 600,
            "uptime": 0,
        }]},
        "/api2/json/nodes/node-a/storage": {"data": [{
            "storage": "local-lvm", "revision": 41, "status": "available",
            "used": 25_000, "avail": 75_000, "total": 100_000,
        }]},
        "/api2/json/nodes/node-a/tasks": {"data": [{
            "upid": RAW_UPID, "type": "qmstart", "status": "OK",
            "starttime": 100, "endtime": 110,
        }]},
    }
    values.update(changes)
    return values


@contextmanager
def origin(payloads, *, delay=0):
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
                if not line or line == b"\r\n":
                    break
                headers.append(line.decode("latin1").rstrip("\r\n"))
            method, path, _version = first.decode("ascii").strip().split(" ")
            requests.append((method, path, headers))
            time.sleep(delay)
            selected = payloads.get(path)
            status = b"200 OK" if selected is not None else b"404 Not Found"
            body = json.dumps(selected if selected is not None else {}).encode()
            try:
                self.request.sendall(
                    b"HTTP/1.1 " + status
                    + b"\r\nContent-Type: application/json\r\nContent-Length: "
                    + str(len(body)).encode() + b"\r\n\r\n" + body
                )
            except OSError:
                pass

    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    with Server(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(
            target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True,
        )
        thread.start()
        try:
            yield server.server_address[1], requests
        finally:
            server.shutdown()
            thread.join(1)


def loopback(_host, port):
    return [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "",
             ("127.0.0.1", port))]


def configured(tmp_path, port, *, clock=time.time, monotonic=time.monotonic,
               resolver=loopback, **observer_options):
    key = tmp_path / "binding.key"
    key.write_bytes(b"k" * 32)
    key.chmod(0o600)
    envelope = tmp_path / "credential.bin"
    seal_service_binding(envelope, key, binding(port))
    issuer = ServiceCredentialLeaseIssuer(
        envelope, key, clock=monotonic, lease_ttl=2,
    )
    observer = ProxmoxTelemetryObserver(
        issuer, clock=clock, monotonic=monotonic, resolver=resolver,
        **observer_options,
    )
    return issuer, observer


def test_live_matrix_is_typed_revision_bound_and_secret_free(tmp_path):
    with origin(responses()) as (port, requests):
        issuer, observer = configured(tmp_path, port)
        snapshot = observer.poll(
            expectation(), deadline=time.monotonic() + 3,
            cancelled=lambda: False,
        )
    assert snapshot.availability == "live"
    assert snapshot.resource_revision == 5
    assert snapshot.binding_revision == 7
    assert snapshot.service_revision == 9
    assert snapshot.node.revision == 11
    assert snapshot.node.cpu_ratio == 0.25
    assert snapshot.node.memory_used == 4_000
    assert snapshot.node.disk_used == 20_000
    assert snapshot.node.network_rx == 1_000
    assert snapshot.node.uptime_seconds == 3_600
    assert [(guest.kind, guest.guest_id, guest.revision, guest.status)
            for guest in snapshot.guests] == [
                ("qemu", 101, 21, "running"),
                ("lxc", 202, 31, "stopped"),
            ]
    assert snapshot.storages[0].name == "local-lvm"
    assert snapshot.tasks[0].operation_ref == (
        "UPID-SHA256:" + hashlib.sha256(RAW_UPID.encode()).hexdigest()
    )
    assert snapshot.tasks[0].status == "succeeded"
    assert [item[:2] for item in requests] == [
        ("GET", "/api2/json/nodes/node-a/status"),
        ("GET", "/api2/json/nodes/node-a/qemu"),
        ("GET", "/api2/json/nodes/node-a/lxc"),
        ("GET", "/api2/json/nodes/node-a/storage"),
        ("GET", "/api2/json/nodes/node-a/tasks"),
    ]
    assert all(any(TOKEN in header for header in item[2]) for item in requests)
    public = repr(snapshot) + json.dumps(snapshot.to_public()) + repr(issuer)
    assert not any(secret in public for secret in (
        TOKEN, RAW_UPID, "proxmox.fixture", "larenor@pve!tablet",
    ))


def test_credential_lease_is_short_lived_revision_bound_and_zeroized(tmp_path):
    with origin(responses()) as (port, _requests):
        issuer, _observer = configured(tmp_path, port)
        lease = issuer.issue(expectation(), deadline=time.monotonic() + 3)
        backing = lease._credential  # Owned buffer inspection; never a public API.
        assert TOKEN.encode() in bytes(backing)
        assert TOKEN in lease.authorization()
        lease.close()
        assert bytes(backing) == b"\0" * len(backing)
        assert lease.cleared is True
        with pytest.raises(CredentialLeaseError, match="^lease_unavailable$"):
            lease.authorization()

        with pytest.raises(CredentialLeaseError, match="^binding_changed$"):
            issuer.issue(
                expectation(service_revision=10), deadline=time.monotonic() + 3,
            )


def test_network_loss_is_offline_then_cached_live_data_is_bounded_stale(tmp_path):
    now = [100.0]
    mono = [10.0]
    with origin(responses()) as (port, _requests):
        _issuer, observer = configured(
            tmp_path, port, clock=lambda: now[0], monotonic=lambda: mono[0],
            max_stale_seconds=30,
        )
        live = observer.poll(expectation(), deadline=12, cancelled=lambda: False)
    now[0], mono[0] = 110.0, 11.0
    stale = observer.poll(expectation(), deadline=12, cancelled=lambda: False)
    assert stale.availability == "stale"
    assert stale.observed_at == live.observed_at
    assert stale.polled_at == 110.0
    assert stale.guests == live.guests

    changed = observer.poll(
        expectation(service_revision=10), deadline=12, cancelled=lambda: False,
    )
    assert changed.availability == "schema_drift"
    assert changed.node is None and changed.guests == ()

    now[0], mono[0] = 131.0, 12.0
    offline = observer.poll(expectation(), deadline=13, cancelled=lambda: False)
    assert offline.availability == "offline"
    assert offline.node is None and offline.guests == ()


@pytest.mark.parametrize("provider_status,public_status", [
    ("OK", "succeeded"),
    ("running", "executing"),
    ("ERROR", "failed"),
    ("unknown", "unknown"),
])
def test_task_status_matrix_is_typed_and_raw_upid_is_redacted(
    tmp_path, provider_status, public_status,
):
    fixture = responses()
    fixture["/api2/json/nodes/node-a/tasks"]["data"][0]["status"] = provider_status
    with origin(fixture) as (port, _requests):
        _issuer, observer = configured(tmp_path, port)
        snapshot = observer.poll(
            expectation(), deadline=time.monotonic() + 2,
            cancelled=lambda: False,
        )
    assert snapshot.availability == "live"
    assert snapshot.tasks[0].status == public_status
    assert RAW_UPID not in repr(snapshot)


def test_schema_drift_and_revision_drift_never_reuse_cached_values(tmp_path):
    with origin(responses()) as (port, _requests):
        _issuer, observer = configured(tmp_path, port)
        assert observer.poll(
            expectation(), deadline=time.monotonic() + 2,
            cancelled=lambda: False,
        ).availability == "live"
    drift = responses()
    drift["/api2/json/nodes/node-a/qemu"] = {
        "data": [{"vmid": 101, "revision": 22, "status": "running"}],
    }
    with origin(drift) as (port, _requests):
        _issuer, changed = configured(tmp_path, port)
        snapshot = changed.poll(
            expectation(), deadline=time.monotonic() + 2,
            cancelled=lambda: False,
        )
    assert snapshot.availability == "schema_drift"
    assert snapshot.node is None and snapshot.guests == ()


def test_deadline_cancel_body_limit_and_dns_rebinding_fail_closed(tmp_path):
    with origin(responses(), delay=0.1) as (port, requests):
        _issuer, observer = configured(tmp_path, port)
        result = observer.poll(
            expectation(), deadline=time.monotonic() + 0.03,
            cancelled=lambda: False,
        )
        assert result.availability == "offline"
        assert len(requests) <= 1

    with origin(responses()) as (port, requests):
        _issuer, observer = configured(
            tmp_path, port,
            resolver=lambda _host, selected: [(
                socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "",
                ("127.0.0.2", selected),
            )],
        )
        assert observer.poll(
            expectation(), deadline=time.monotonic() + 2,
            cancelled=lambda: False,
        ).availability == "offline"
        assert requests == []

    huge = responses()
    huge["/api2/json/nodes/node-a/status"] = {
        "data": {"padding": "x" * 70_000},
    }
    with origin(huge) as (port, _requests):
        _issuer, observer = configured(tmp_path, port)
        assert observer.poll(
            expectation(), deadline=time.monotonic() + 2,
            cancelled=lambda: False,
        ).availability == "offline"

    with origin(responses()) as (port, requests):
        _issuer, observer = configured(tmp_path, port)
        assert observer.poll(
            expectation(), deadline=time.monotonic() + 2,
            cancelled=lambda: True,
        ).availability == "offline"
        assert requests == []
