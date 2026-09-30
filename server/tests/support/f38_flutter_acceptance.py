"""Run the real Flutter F38 client against normal Core and TCP Immich."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import auth, ready, server as core_fixture


ALBUM = "11111111-1111-4111-8111-111111111111"
OTHER_ALBUM = "22222222-2222-4222-8222-222222222222"
ASSET = "44444444-4444-4444-8444-444444444444"
OTHER_ASSET = "55555555-5555-4555-8555-555555555555"
KEY = "fixture-immich-read-key"


def _asset(asset_id, name):
    return {
        "id": asset_id,
        "type": "IMAGE",
        "originalFileName": name,
        "fileCreatedAt": "2026-08-31T19:30:00.000Z",
        "thumbhash": "AQIDBA==",
        "checksum": "fixture-" + asset_id,
    }


class ImmichFixture:
    def __init__(self):
        self.calls = []
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def _send(self, value):
                raw = json.dumps(value).encode()
                self.send_response(200 if self.headers.get("x-api-key") == KEY else 401)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                fixture.calls.append(("GET", self.path, None))
                if self.path == "/api/server/about":
                    self._send({"version": "3.2.4"})
                elif self.path == "/api/albums":
                    self._send([
                        {"id": ALBUM, "albumName": "Trip"},
                        {"id": OTHER_ALBUM, "albumName": "Archive"},
                    ])
                else:
                    raise AssertionError("unexpected Immich GET " + self.path)

            def do_POST(self):
                if self.path != "/api/search/smart":
                    raise AssertionError("unexpected Immich POST " + self.path)
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                fixture.calls.append(("POST", self.path, body))
                album = body["filter"]["albumIds"]["any"]
                if album == [ALBUM]:
                    items = [_asset(ASSET, "Trip.jpg"), _asset(OTHER_ASSET, "Shared.jpg")]
                elif album == [OTHER_ALBUM]:
                    items = [_asset(OTHER_ASSET, "Shared.jpg")]
                else:
                    raise AssertionError("search was not confined to one album")
                self._send({"assets": {"items": items}})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f38-client-") as root:
        generator = core_fixture.__wrapped__(Path(root))
        fixture = next(generator)
        app, client, _settings, _clock = fixture
        immich = ImmichFixture()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        running = uvicorn.Server(uvicorn.Config(app, log_level="critical", access_log=False))
        thread = threading.Thread(target=lambda: running.run(sockets=[listener]), daemon=True)
        try:
            actor = ready(fixture)
            response = client.post("/api/v1/admin/services", headers=auth(actor), json={
                "name": "Fixture photos",
                "kind": "immich",
                "baseUrl": immich.url,
                "credentials": {"apiKey": KEY},
            })
            if response.status_code != 201:
                raise RuntimeError("service_setup_failed:" + response.text)
            service = response.json()["service"]
            principal = app.state.core.auth.authenticate(actor["accessToken"])
            app.state.core.services.record_verification(
                principal, service["id"], service["revision"],
                state="authenticated", version="3.2.4",
            )
            thread.start()
            deadline = time.monotonic() + 5
            while not running.started:
                if not thread.is_alive() or time.monotonic() >= deadline:
                    raise RuntimeError("isolated_core_startup_failed")
                time.sleep(0.02)
            result = subprocess.run(
                ["flutter", "test", "test/features/server/"
                 "server_family_memories_normal_core_test.dart"],
                env={**os.environ, "LARENOR_MEMORY_CORE_URL":
                     f"http://127.0.0.1:{listener.getsockname()[1]}"},
                cwd=Path(__file__).resolve().parents[3],
                check=False,
            )
            posts = [call for call in immich.calls if call[0] == "POST"]
            if len(posts) != 2 or [call[2]["filter"]["albumIds"]["any"]
                                   for call in posts] != [[ALBUM], [OTHER_ALBUM]]:
                raise RuntimeError("album_confinement_failed:" + repr(posts))
            return result.returncode
        finally:
            running.should_exit = True
            if thread.is_alive():
                thread.join(timeout=5)
            listener.close()
            immich.close()
            generator.close()


if __name__ == "__main__":
    sys.exit(main())
