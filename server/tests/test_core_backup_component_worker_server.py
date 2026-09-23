"""S09.1 host-owned component snapshot worker server boundary."""

import os
import socket
import threading
import time
from contextlib import contextmanager

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
def worker(tmp_path, boundary, *, client_uid=None):
    path = tmp_path / "private" / "component.sock"
    path.parent.mkdir(mode=0o700)
    server = ComponentSnapshotWorkerServer(
        path,
        boundary,
        owner_uid=os.getuid(),
        peer_uid=(lambda _connection: os.getuid())
        if client_uid is None
        else (lambda _connection: client_uid),
    )
    thread = threading.Thread(target=server.serve_once, daemon=True)
    thread.start()
    assert server.wait_ready(2)
    try:
        yield path, server
    finally:
        server.close()
        thread.join(2)
        assert not thread.is_alive()


def client(path):
    return ComponentSnapshotWorkerClient(
        path,
        owner_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(),
    )


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
    with worker(tmp_path, boundary, client_uid=os.getuid() + 1) as (path, _server):
        with (
            pytest.raises(ComponentSnapshotWorkerError),
            client(path).quiesce(time.monotonic() + 2),
        ):
            raise AssertionError("must_not_yield")
    assert boundary.entered == boundary.released == 0


def test_server_provider_failure_is_static_and_releases_boundary(tmp_path):
    boundary = Boundary(snapshots(), fail=True)
    with worker(tmp_path, boundary) as (path, server):
        with (
            pytest.raises(ComponentSnapshotWorkerError, match="worker_unavailable"),
            client(path).quiesce(time.monotonic() + 2),
        ):
            raise AssertionError("must_not_yield")
        assert server.completed == 0
    assert boundary.entered == boundary.released == 1


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

    private = tmp_path / "private"
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
