"""Actual Flutter profile vault -> two normal Cores -> Jellyfin TCP probe."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import ready, server as core_fixture


TOKENS = {
    "f19-home-a-private-token": "10.11.1",
    "f19-home-b-private-token": "10.11.2",
}


class JellyfinFixture(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    reads = {token: 0 for token in TOKENS}

    def do_GET(self):
        token = self.headers.get("X-Emby-Token")
        if self.path != "/System/Info" or token not in TOKENS:
            self.send_error(401)
            return
        type(self).reads[token] += 1
        body = json.dumps({
            "ProductName": "Jellyfin Server",
            "Version": TOKENS[token],
            "StartupWizardCompleted": True,
        }).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


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


def _stop(server, thread, listener):
    server.should_exit = True
    thread.join(timeout=5)
    listener.close()


def _flutter(phase, store, core_a, core_b, jellyfin):
    return subprocess.run(
        [
            "flutter", "test",
            "test/features/server/server_multi_core_normal_test.dart",
        ],
        cwd=Path(__file__).resolve().parents[3],
        env={
            **os.environ,
            "LARENOR_F19_PHASE": phase,
            "LARENOR_F19_STORE": str(store),
            "LARENOR_F19_CORE_A": core_a,
            "LARENOR_F19_CORE_B": core_b,
            "LARENOR_F19_JELLYFIN": jellyfin,
        },
        check=False,
    ).returncode


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f19-client-") as root:
        root = Path(root)
        generator_a = core_fixture.__wrapped__(root / "core-a")
        generator_b = core_fixture.__wrapped__(root / "core-b")
        fixture_a = next(generator_a)
        fixture_b = next(generator_b)
        app_a, _client_a, _settings_a, clock_a = fixture_a
        app_b, _client_b, _settings_b, clock_b = fixture_b
        clock_a.now = clock_b.now = time.time()
        ready(fixture_a)
        ready(fixture_b)

        upstream = ThreadingHTTPServer(("127.0.0.1", 0), JellyfinFixture)
        upstream_thread = threading.Thread(
            target=upstream.serve_forever, daemon=True
        )
        upstream_thread.start()
        jellyfin = f"http://127.0.0.1:{upstream.server_port}"
        core_a = _serve(app_a)
        core_b = _serve(app_b)
        store = root / "client-profile-vault.json"
        try:
            if _flutter("prepare", store, core_a[0], core_b[0], jellyfin) != 0:
                raise RuntimeError("multi_core_prepare_failed")
            if JellyfinFixture.reads != {
                "f19-home-a-private-token": 1,
                "f19-home-b-private-token": 1,
            }:
                raise RuntimeError("multi_core_provider_probe_failed")

            _stop(core_a[1], core_a[2], core_a[3])
            core_a = None
            if _flutter("restart", store, "http://127.0.0.1:1", core_b[0], jellyfin) != 0:
                raise RuntimeError("multi_core_restart_failed")
            if JellyfinFixture.reads != {
                "f19-home-a-private-token": 1,
                "f19-home-b-private-token": 1,
            }:
                raise RuntimeError("unexpected_provider_io_after_restart")
            return 0
        finally:
            if core_a is not None:
                _stop(core_a[1], core_a[2], core_a[3])
            _stop(core_b[1], core_b[2], core_b[3])
            upstream.shutdown()
            upstream.server_close()
            upstream_thread.join(timeout=5)
            generator_a.close()
            generator_b.close()


if __name__ == "__main__":
    sys.exit(main())
