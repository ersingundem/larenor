"""Actual Linux AF_UNIX access and SO_PEERCRED across packaged UIDs."""

import os
from pathlib import Path
import shutil
import stat
import sys
import time

import pytest

from larenor_server.plugins.media_archive_worker_ipc import (
    MediaArchiveWorkerClient,
    MediaArchiveWorkerServer,
)
from larenor_server.plugins.preflight_ipc import (
    PreflightWorkerClient, PreflightWorkerServer,
)


class ReadyCollector:
    def current(self, _installation_id):
        raise ValueError()

    def collect(self, _private, *, deadline, gate):
        raise ValueError()


def _identity(uid, gid):
    os.setgroups([gid])
    os.setgid(uid)
    os.setuid(uid)


def _serve(path, owner_uid, peer_uid, gid, ready, stop):
    try:
        _identity(owner_uid, gid)
        server = MediaArchiveWorkerServer(
            path, ReadyCollector(), allowed_uid=peer_uid,
            socket_gid=gid, timeout=2,
        )
        server.start()
        os.write(ready, b"1")
        os.read(stop, 1)
        server.close()
        os._exit(0)
    except BaseException:
        try:
            os.write(ready, b"0")
        finally:
            os._exit(1)


def _client(path, owner_uid, client_uid, gid):
    try:
        _identity(client_uid, gid)
        result = MediaArchiveWorkerClient(path, owner_uid=owner_uid, timeout=2).status()
        os._exit(0 if result["state"] == "ready" else 1)
    except BaseException:
        os._exit(1)


def _preflight_client(path, gid):
    try:
        _identity(10001, gid)
        result = PreflightWorkerClient(path, owner_uid=0, timeout=2).status()
        os._exit(0 if result["capability"] == "preflight" else 1)
    except BaseException:
        os._exit(1)


@pytest.mark.skipif(
    sys.platform != "linux" or os.geteuid() != 0,
    reason="requires the native Linux root runner to switch exact deployment UIDs",
)
def test_uid1000_worker_and_uid10001_core_share_only_gid10002_socket_access():
    root = Path(f"/tmp/larenor-host-ipc-{os.getpid()}")
    root.mkdir(mode=0o755)
    cases = ((1000, 10001, "archive"), (10001, 1000, "core"))
    try:
        for owner_uid, peer_uid, name in cases:
            parent = root / name
            parent.mkdir(mode=0o750)
            os.chown(parent, owner_uid, 10002)
            path = parent / "worker.sock"
            ready_read, ready_write = os.pipe()
            stop_read, stop_write = os.pipe()
            server_pid = os.fork()
            if server_pid == 0:
                os.close(ready_read)
                os.close(stop_write)
                _serve(path, owner_uid, peer_uid, 10002, ready_write, stop_read)
            os.close(ready_write)
            os.close(stop_read)
            assert os.read(ready_read, 1) == b"1"
            info = path.stat()
            assert (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (
                owner_uid, 10002, 0o660)
            client_pid = os.fork()
            if client_pid == 0:
                _client(path, owner_uid, peer_uid, 10002)
            assert os.waitpid(client_pid, 0)[1] == 0
            os.write(stop_write, b"1")
            assert os.waitpid(server_pid, 0)[1] == 0
            os.close(ready_read)
            os.close(stop_write)
            assert not path.exists()
    finally:
        shutil.rmtree(root)


@pytest.mark.skipif(
    sys.platform != "linux" or os.geteuid() != 0,
    reason="requires the native Linux root runner to switch exact deployment UIDs",
)
def test_root_worker_socket_under_core_owned_data_keeps_exact_peer_identity():
    root = Path(f"/tmp/larenor-root-worker-ipc-{os.getpid()}")
    core = root / "core"
    parent = core / "root"
    try:
        root.mkdir(mode=0o755)
        core.mkdir(mode=0o750)
        os.chown(core, 10001, 10002)
        parent.mkdir(mode=0o750)
        os.chown(parent, 0, 10002)
        path = parent / "preflight.sock"
        server = PreflightWorkerServer(
            path, object(), platform="linux/amd64", allowed_uid=10001,
            socket_gid=10002, timeout=2,
        )
        server.start()
        try:
            info = path.stat()
            assert (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) == (
                0, 10002, 0o660)
            client_pid = os.fork()
            if client_pid == 0:
                _preflight_client(path, 10002)
            assert os.waitpid(client_pid, 0)[1] == 0
        finally:
            server.close()
    finally:
        shutil.rmtree(root)
