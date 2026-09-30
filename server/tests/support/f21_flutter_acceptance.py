"""Run two production Flutter clients through a normal restartable F21 Core."""

from pathlib import Path
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

from fastapi.testclient import TestClient
import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import Clock, login
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.plugins.media_archive_read_collector import (
    MediaArchiveReadCollector,
)
from support.f21_media_stack_fixture import MediaStackFixture
from test_admin import PERMANENT, activate, create as create_user
from test_media_archive_provider import provision


def _serve(app):
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    server = uvicorn.Server(uvicorn.Config(
        app, log_level="critical", access_log=False
    ))
    thread = threading.Thread(
        target=lambda: server.run(sockets=[listener]), daemon=True
    )
    thread.start()
    deadline = time.monotonic() + 5
    while not server.started:
        if not thread.is_alive() or time.monotonic() >= deadline:
            raise RuntimeError("isolated_core_startup_failed")
        time.sleep(0.02)
    return (
        f"http://127.0.0.1:{listener.getsockname()[1]}",
        server,
        thread,
        listener,
    )


def _stop(value):
    value[1].should_exit = True
    value[2].join(timeout=5)
    value[3].close()


def _flutter(phase, core_url, state_file):
    return subprocess.run(
        [
            "flutter", "test",
            "test/features/server/server_watch_party_normal_core_test.dart",
        ],
        cwd=Path(__file__).resolve().parents[3],
        env={
            **os.environ,
            "LARENOR_F21_PHASE": phase,
            "LARENOR_F21_CORE_URL": core_url,
            "LARENOR_F21_STATE": str(state_file),
            "LARENOR_F21_MEMBER_PASSWORD": PERMANENT,
        },
        check=False,
    ).returncode


class _ArchiveWorker:
    """The production collector behind the same method as the host IPC client."""

    def __init__(self, collector, upstream):
        self.collector = collector
        self.upstream = upstream

    def read_media_archive(self, private, *, deadline, gate):
        jellyfin = next(
            value for value in private.sources
            if value.serviceId == "jellyfin"
        )
        self.upstream.bind_server_id(jellyfin.serverId)
        return self.collector.collect(private, deadline=deadline, gate=gate)


def _app(settings, collector, upstream):
    return create_app(
        settings, media_archive_worker=_ArchiveWorker(collector, upstream)
    )


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f21-client-") as root:
        root = Path(root).resolve()
        clock = Clock(time.time())
        settings = Settings(
            root / "data", root / "secrets/vault.key", clock=clock,
            login_ip_limit=100, login_account_limit=100,
            login_global_limit=100,
        )
        upstream = MediaStackFixture()
        upstream.start()
        collector = MediaArchiveReadCollector(clock=lambda: int(clock.now))
        state_file = root / "watch-party.json"
        app = _app(settings, collector, upstream)
        running = None
        try:
            with TestClient(app) as client:
                fixture = (app, client, settings, clock)
                provision(fixture)
                admin = login(
                    client, "admin", "Synthetic new password 2026"
                ).json()
                create_user(client, admin, "watch-member")
                activate(client, "watch-member")
                running = _serve(app)
                if _flutter("prepare", running[0], state_file) != 0:
                    raise RuntimeError("watch_party_prepare_failed")
                upstream.assert_one_read_only_collection()
                _stop(running)
                running = None

            # A fresh Core instance must verify the sealed room and archive
            # snapshot without requiring a provider read while the snapshot is
            # still current.
            upstream.close()
            calls_before_restart = list(upstream.calls)
            restarted = _app(settings, collector, upstream)
            with TestClient(restarted):
                running = _serve(restarted)
                if _flutter("restart", running[0], state_file) != 0:
                    raise RuntimeError("watch_party_restart_failed")
                if upstream.calls != calls_before_restart:
                    raise RuntimeError("unexpected_provider_io_after_restart")
                _stop(running)
                running = None
            return 0
        finally:
            if running is not None:
                _stop(running)
            upstream.close()


if __name__ == "__main__":
    sys.exit(main())
