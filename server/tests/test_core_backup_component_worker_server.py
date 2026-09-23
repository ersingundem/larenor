"""S09.1 host-owned component snapshot worker server boundary."""

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

from larenor_server.core_backups.component_worker import (
    ComponentSnapshotWorkerClient,
    ComponentSnapshotWorkerError,
)
from larenor_server.core_backups.component_worker_server import (
    ComponentSnapshotWorkerServer,
)
from larenor_server.core_backups.service import ComponentVolumeSnapshot


class Boundary:
    def __init__(self, snapshots, *, fail=False):
        self.snapshots = snapshots
        self.fail = fail
        self.entered = 0
        self.released = 0
        self.active = False

    @contextmanager
    def quiesce(self, deadline):
        assert time.monotonic() < deadline <= time.monotonic() + 5
        self.entered += 1
        self.active = True
        try:
            if self.fail:
                raise RuntimeError("private provider detail")
            yield self.snapshots
        finally:
            self.active = False
            self.released += 1


def snapshots():
    common = {
        "serviceId": "jellyfin",
        "serviceVersion": "10.11.11",
        "configSchemaVersion": 1,
        "dataSchemaVersion": "upstream_managed_unverified",
    }
    return (
        ComponentVolumeSnapshot(
            **common,
            volumeId="jellyfin-cache",
            payload=b"bounded cache snapshot\n",
        ),
        ComponentVolumeSnapshot(
            **common,
            volumeId="jellyfin-config",
            payload=b"bounded config snapshot\n",
        ),
    )


@contextmanager
def worker(
    tmp_path,
    boundary,
    *,
    allowed_client_uid=None,
    observed_peer_uid=None,
):
    del tmp_path
    path = (
        Path("/tmp").resolve()
        / f"larenor-worker-{uuid.uuid4().hex}"
        / "component.sock"
    )
    path.parent.mkdir(mode=0o700)
    server = ComponentSnapshotWorkerServer(
        path,
        boundary,
        owner_uid=os.getuid(),
        client_uid=(
            os.getuid() if allowed_client_uid is None else allowed_client_uid
        ),
        peer_uid=(lambda _connection: os.getuid())
        if observed_peer_uid is None
        else observed_peer_uid
        if callable(observed_peer_uid)
        else (lambda _connection: observed_peer_uid),
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    assert server.wait_ready(2)
    try:
        yield path, server
    finally:
        server.close()
        thread.join(2)
        assert not thread.is_alive()
        path.parent.rmdir()


def client(path):
    return ComponentSnapshotWorkerClient(
        path,
        owner_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(),
    )


def write_frame(connection, value):
    raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("ascii")
    connection.sendall(struct.pack("!I", len(raw)) + raw)


def read_exact(connection, count):
    result = bytearray()
    while len(result) < count:
        part = connection.recv(count - len(result))
        assert part
        result.extend(part)
    return bytes(result)


def read_frame(connection):
    count = struct.unpack("!I", read_exact(connection, 4))[0]
    return json.loads(read_exact(connection, count))


def test_server_holds_exact_quiescence_until_authenticated_release(tmp_path):
    boundary = Boundary(snapshots())
    with worker(tmp_path, boundary) as (path, server):
        with client(path).quiesce(time.monotonic() + 2) as captured:
            assert boundary.active
            assert captured == snapshots()
        assert not boundary.active
        assert boundary.entered == boundary.released == 1
        assert server.completed == 1

    assert not path.exists()


def test_server_rejects_foreign_peer_before_provider_and_recovers(tmp_path):
    boundary = Boundary(snapshots())
    peers = iter((os.getuid() + 1, os.getuid()))
    with worker(
        tmp_path,
        boundary,
        observed_peer_uid=lambda _connection: next(peers),
    ) as (
        path,
        _server,
    ):
        with (
            pytest.raises(ComponentSnapshotWorkerError),
            client(path).quiesce(time.monotonic() + 2),
        ):
            raise AssertionError("must_not_yield")
        with client(path).quiesce(time.monotonic() + 2) as captured:
            assert captured == snapshots()
    assert boundary.entered == boundary.released == 1


def test_server_allows_client_uid_to_differ_from_socket_owner(tmp_path):
    boundary = Boundary(snapshots())
    allowed_uid = os.getuid() + 7
    with worker(
        tmp_path,
        boundary,
        allowed_client_uid=allowed_uid,
        observed_peer_uid=allowed_uid,
    ) as (path, server):
        assert path.lstat().st_uid == os.getuid()
        with client(path).quiesce(time.monotonic() + 2) as captured:
            assert captured == snapshots()
        assert server.completed == 1


@pytest.mark.parametrize("client_uid", [-1, 2**31, True, "10001"])
def test_server_rejects_invalid_client_uid(tmp_path, client_uid):
    parent = Path("/tmp").resolve() / f"larenor-worker-{uuid.uuid4().hex}"
    parent.mkdir(mode=0o700)
    try:
        with pytest.raises(ValueError, match="invalid_worker_configuration"):
            ComponentSnapshotWorkerServer(
                parent / "component.sock",
                Boundary(snapshots()),
                owner_uid=os.getuid(),
                client_uid=client_uid,
                peer_uid=lambda _connection: os.getuid(),
            )
    finally:
        parent.rmdir()


def test_server_provider_failure_is_static_and_releases_boundary(tmp_path):
    boundary = Boundary(snapshots(), fail=True)
    with worker(tmp_path, boundary) as (path, server):
        with (
            pytest.raises(ComponentSnapshotWorkerError) as error,
            client(path).quiesce(time.monotonic() + 2),
        ):
            raise AssertionError("must_not_yield")
        assert str(error.value) in {"worker_unavailable", "invalid_worker_result"}
        assert "private provider detail" not in str(error.value)
        boundary.fail = False
        with client(path).quiesce(time.monotonic() + 2) as captured:
            assert captured == snapshots()
        assert server.completed == 1
    assert boundary.entered == boundary.released == 2


def test_server_rejects_foreign_release_and_remains_available(tmp_path):
    boundary = Boundary(snapshots())
    with worker(tmp_path, boundary) as (path, server):
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(2)
        connection.connect(str(path))
        request_id = "1" * 32
        write_frame(
            connection,
            {
                "protocol": 1,
                "requestId": request_id,
                "operation": "quiesce",
                "timeoutMilliseconds": 1500,
            },
        )
        ready = read_frame(connection)
        assert ready["requestId"] == request_id
        for descriptor in ready["snapshots"]:
            read_exact(connection, descriptor["byteLength"])
        write_frame(
            connection,
            {
                "protocol": 1,
                "requestId": "2" * 32,
                "operation": "release",
            },
        )
        assert connection.recv(1) == b""
        connection.close()
        assert boundary.entered == boundary.released == 1

        with client(path).quiesce(time.monotonic() + 2) as captured:
            assert captured == snapshots()
        assert server.completed == 1


def test_server_rejects_insecure_parent_and_preserves_replaced_socket(tmp_path):
    parent = tmp_path / "public"
    parent.mkdir(mode=0o777)
    os.chmod(parent, 0o777)
    with pytest.raises(ValueError, match="invalid_worker_configuration"):
        ComponentSnapshotWorkerServer(
            parent / "component.sock",
            Boundary(snapshots()),
            owner_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(),
        )

    private = Path("/tmp").resolve() / f"larenor-worker-{uuid.uuid4().hex}"
    private.mkdir(mode=0o700)
    path = private / "component.sock"
    server = ComponentSnapshotWorkerServer(
        path,
        Boundary(snapshots()),
        owner_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(),
    )
    thread = threading.Thread(target=server.serve_once, daemon=True)
    thread.start()
    assert server.wait_ready(2)
    path.unlink()
    replacement = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    replacement.bind(str(path))
    try:
        server.close()
        thread.join(2)
        assert path.exists()
    finally:
        replacement.close()
        path.unlink(missing_ok=True)
        private.rmdir()
