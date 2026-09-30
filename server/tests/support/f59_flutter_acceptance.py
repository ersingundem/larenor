"""Actual Flutter -> normal Core -> authenticated OctoPrint TCP acceptance."""

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
from conftest import auth, ready, server as core_fixture
from larenor_server.app import create_app


API_KEY = "f59-private-fixture-key"


class OctoPrintFixture(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    state = "Printing"
    posts = 0
    reads = 0

    def _reply(self, status, value=None):
        body = b"" if value is None else json.dumps(value).encode("utf-8")
        self.send_response(status)
        if value is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        cls = type(self)
        assert self.headers.get("X-Api-Key") == API_KEY
        cls.reads += 1
        if self.path == "/api/job":
            self._reply(200, {
                "job": {"file": {
                    "name": "part.gcode", "path": "models/part.gcode",
                    "origin": "local", "size": 1200,
                    "date": 1_700_000_000,
                }},
                "progress": {"completion": 40.0, "printTimeLeft": 600},
                "state": cls.state,
            })
            return
        if self.path == "/api/printer?exclude=sd":
            paused = cls.state == "Paused"
            self._reply(200, {
                "state": {"flags": {
                    "operational": False,
                    "paused": paused,
                    "printing": not paused,
                    "cancelling": False,
                    "pausing": False,
                    "error": False,
                    "ready": False,
                    "closedOrError": False,
                }, "text": cls.state},
                "temperature": {
                    "tool0": {"actual": 214.8, "target": 220.0},
                    "bed": {"actual": 60.1, "target": 60.0},
                },
            })
            return
        self._reply(404, {"error": "unknown"})

    def do_POST(self):
        cls = type(self)
        assert self.path == "/api/job"
        assert self.headers.get("X-Api-Key") == API_KEY
        length = int(self.headers.get("Content-Length", "0"))
        assert json.loads(self.rfile.read(length)) == {
            "action": "pause", "command": "pause",
        }
        cls.posts += 1
        cls.state = "Paused"
        self._reply(204)

    def log_message(self, *_args):
        pass


def _serve(app, listener):
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
    return server, thread


def _flutter(url, phase):
    return subprocess.run(
        [
            "flutter", "test",
            "test/features/workshop/workshop_normal_core_test.dart",
        ],
        cwd=Path(__file__).resolve().parents[3],
        env={
            **os.environ,
            "LARENOR_WORKSHOP_CORE_URL": url,
            "LARENOR_WORKSHOP_PHASE": phase,
        },
        check=False,
    ).returncode


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f59-client-") as root:
        generator = core_fixture.__wrapped__(Path(root))
        fixture = next(generator)
        app, client, settings, clock = fixture
        clock.now = time.time()
        upstream = ThreadingHTTPServer(("127.0.0.1", 0), OctoPrintFixture)
        upstream_thread = threading.Thread(
            target=upstream.serve_forever, daemon=True
        )
        upstream_thread.start()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        url = f"http://127.0.0.1:{listener.getsockname()[1]}"
        second_listener = None
        first_server = first_thread = None
        second_server = second_thread = None
        try:
            pair = ready(fixture)
            service = client.post(
                "/api/v1/admin/services", headers=auth(pair), json={
                    "name": "Actual OctoPrint",
                    "kind": "octoprint",
                    "baseUrl": f"http://127.0.0.1:{upstream.server_port}",
                    "credentials": {"apiKey": API_KEY},
                },
            )
            if service.status_code != 201:
                raise RuntimeError("workshop_fixture_setup_failed")
            saved = service.json()["service"]
            actor = app.state.core.auth.authenticate(pair["accessToken"])
            app.state.core.services.record_verification(
                actor, saved["id"], saved["revision"],
                state="authenticated", version="1.10.3",
            )

            first_server, first_thread = _serve(app, listener)
            if _flutter(url, "prepare") != 0:
                raise RuntimeError("workshop_client_prepare_failed")
            first_server.should_exit = True
            first_thread.join(timeout=5)
            first_server = first_thread = None
            listener.close()
            generator.close()

            restarted = create_app(settings)
            second_listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            second_listener.bind(("127.0.0.1", 0))
            second_url = (
                f"http://127.0.0.1:{second_listener.getsockname()[1]}"
            )
            second_server, second_thread = _serve(restarted, second_listener)
            if _flutter(second_url, "restart") != 0:
                raise RuntimeError("workshop_client_restart_failed")
            if OctoPrintFixture.posts != 1 or OctoPrintFixture.state != "Paused":
                raise RuntimeError("workshop_command_idempotency_failed")
            return 0
        finally:
            if first_server is not None:
                first_server.should_exit = True
            if first_thread is not None:
                first_thread.join(timeout=5)
            if second_server is not None:
                second_server.should_exit = True
            if second_thread is not None:
                second_thread.join(timeout=5)
            try:
                generator.close()
            except Exception:
                pass
            try:
                listener.close()
            except OSError:
                pass
            if second_listener is not None:
                second_listener.close()
            upstream.shutdown()
            upstream.server_close()
            upstream_thread.join(timeout=5)


if __name__ == "__main__":
    sys.exit(main())
