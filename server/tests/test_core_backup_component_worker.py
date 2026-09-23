"""S09.1 production component-snapshot worker boundary."""

import hashlib
import json
import os
import socket
import struct
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

import pytest

from larenor_server.config import Settings
from larenor_server.core_backups.component_worker import (
    ComponentSnapshotWorkerClient,
    ComponentSnapshotWorkerError,
)
from larenor_server.runtime import create_configured_app


def _write_frame(connection, value):
    raw = json.dumps(value, separators=(",", ":"), sort_keys=True).encode("ascii")
    connection.sendall(struct.pack("!I", len(raw)) + raw)


def _read_exact(connection, count):
    value = bytearray()
    while len(value) < count:
        part = connection.recv(count - len(value))
        if not part:
            raise AssertionError("unexpected_eof")
        value.extend(part)
    return bytes(value)


def _read_frame(connection):
    count = struct.unpack("!I", _read_exact(connection, 4))[0]
    return json.loads(_read_exact(connection, count))


@contextmanager
def _worker(tmp_path, snapshots, payloads, observed):
    del tmp_path
    path = Path("/tmp") / f"larenor-component-{uuid.uuid4().hex}.sock"
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(path))
    os.chmod(path, 0o600)
    listener.listen(1)

    def serve():
        with listener:
            connection, _ = listener.accept()
            with connection:
                try:
                    request = _read_frame(connection)
                except AssertionError:
                    return
                observed.append(request)
                _write_frame(
                    connection,
                    {
                        "protocol": 1,
                        "requestId": request["requestId"],
                        "status": "ready",
                        "snapshots": snapshots,
                    },
                )
                for payload in payloads:
                    connection.sendall(payload)
                try:
                    release = _read_frame(connection)
                except AssertionError:
                    return
                observed.append(release)
                _write_frame(
                    connection,
                    {
                        "protocol": 1,
                        "requestId": request["requestId"],
                        "status": "released",
                    },
                )

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        yield path
    finally:
        thread.join(2)
        assert not thread.is_alive()
        path.unlink(missing_ok=True)


def _descriptor(payload, *, volume_id="jellyfin-cache"):
    return {
        "serviceId": "jellyfin",
        "serviceVersion": "10.11.11",
        "configSchemaVersion": 1,
        "dataSchemaVersion": "upstream_managed_unverified",
        "volumeId": volume_id,
        "byteLength": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
    }


def test_component_worker_settings_are_disabled_by_default_and_fail_closed(monkeypatch, tmp_path):
    monkeypatch.setenv("LARENOR_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("LARENOR_KEY_FILE", str(tmp_path / "secret/key"))
    settings = Settings.from_environment()
    assert settings.component_backup_worker_socket is None

    monkeypatch.setenv("LARENOR_COMPONENT_BACKUP_WORKER_UID", "1000")
    with pytest.raises(Exception, match="invalid_worker_configuration"):
        Settings.from_environment()
    monkeypatch.setenv("LARENOR_COMPONENT_BACKUP_WORKER_UID", "0")

    monkeypatch.setenv("LARENOR_COMPONENT_BACKUP_WORKER_SOCKET", "relative.sock")
    with pytest.raises(Exception, match="invalid_worker_configuration"):
        Settings.from_environment()

    monkeypatch.setenv("LARENOR_COMPONENT_BACKUP_WORKER_SOCKET", "/run/larenor/component.sock")
    monkeypatch.setenv("LARENOR_COMPONENT_BACKUP_WORKER_UID", "secret-uid")
    with pytest.raises(Exception, match="invalid_worker_configuration") as error:
        Settings.from_environment()
    assert "secret-uid" not in str(error.value)


def test_component_worker_streams_bounded_payloads_and_releases_same_request(tmp_path):
    cache = b"cache snapshot\n"
    config = b"config snapshot\n"
    observed = []
    with _worker(
        tmp_path,
        [_descriptor(cache), _descriptor(config, volume_id="jellyfin-config")],
        [cache, config],
        observed,
    ) as path:
        client = ComponentSnapshotWorkerClient(
            path,
            owner_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(),
        )
        with client.quiesce(time.monotonic() + 2) as snapshots:
            assert [snapshot.payload for snapshot in snapshots] == [cache, config]

    assert observed[0]["operation"] == "quiesce"
    assert 1 <= observed[0]["timeoutMilliseconds"] <= 2000
    assert observed[1] == {
        "protocol": 1,
        "requestId": observed[0]["requestId"],
        "operation": "release",
    }


def test_component_worker_rejects_untrusted_peer_and_invalid_digest(tmp_path):
    payload = b"snapshot\n"
    observed = []
    with _worker(tmp_path, [_descriptor(payload)], [payload], observed) as path:
        client = ComponentSnapshotWorkerClient(
            path,
            owner_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid() + 1,
        )
        with (
            pytest.raises(ComponentSnapshotWorkerError, match="worker_unavailable"),
            client.quiesce(time.monotonic() + 2),
        ):
            raise AssertionError("must_not_yield")
    assert observed == []

    bad = _descriptor(payload)
    bad["sha256"] = "0" * 64
    observed = []
    with _worker(tmp_path, [bad], [payload], observed) as path:
        client = ComponentSnapshotWorkerClient(
            path,
            owner_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(),
        )
        with (
            pytest.raises(
                ComponentSnapshotWorkerError, match="invalid_worker_result"
            ),
            client.quiesce(time.monotonic() + 2),
        ):
            raise AssertionError("must_not_yield")
    assert observed[1] == {
        "protocol": 1,
        "requestId": observed[0]["requestId"],
        "operation": "release",
    }


def test_configured_app_owns_opted_in_component_worker(tmp_path):
    path = (tmp_path / "component.sock").resolve()
    settings = Settings(
        (tmp_path / "data").resolve(),
        (tmp_path / "secret/key").resolve(),
        component_backup_worker_socket=path,
        component_backup_worker_uid=os.getuid(),
    )

    app = create_configured_app(settings)

    boundary = app.state.core.core_backups._component_boundary
    assert isinstance(boundary, ComponentSnapshotWorkerClient)
    assert boundary.path == path
    assert boundary.owner_uid == os.getuid()
