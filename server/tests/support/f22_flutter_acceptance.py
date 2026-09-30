"""Run the F22 Flutter client through normal Core and owned Jellyfin TCP."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import http.client
import json
import os
import subprocess
import sys
import tempfile
import threading

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import server as core_fixture  # noqa: E402
from larenor_server.plugins.media_playback_models import (  # noqa: E402
    MediaPlaybackReadback,
    MediaPlaybackTarget,
    MediaPlaybackWorkerResult,
)
from support.installed_core_tcp import InstalledCoreTcp  # noqa: E402
from test_media_archive_core_read import (  # noqa: E402
    BindingReader,
    Worker,
    configured,
)


NOW = 1_788_609_610
TARGET = "jellyfin-player:living-room"
ITEM = "b" * 32
TOKEN = "owned-f22-jellyfin-token"


class _Jellyfin(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "JellyfinFixture/10.11"

    def log_message(self, _format, *_args):
        return

    def _authorized(self):
        return self.headers.get("X-Emby-Token") == TOKEN

    def _json(self, status, value):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        if self.path != "/Sessions" or not self._authorized():
            self._json(401 if not self._authorized() else 404, {})
            return
        state = self.server.fixture
        state.calls.append(("GET", self.path))
        self._json(200, [{
            "Id": "c" * 32,
            "DeviceName": "Living room",
            "NowPlayingItem": None if state.item is None else {"Id": state.item},
            "PlayState": {"PositionTicks": state.position * 10_000_000},
        }])

    def do_POST(self):  # noqa: N802
        if self.path != "/Sessions/" + "c" * 32 + "/Playing" or not self._authorized():
            self._json(401 if not self._authorized() else 404, {})
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length < 2 or length > 4096:
            self._json(400, {})
            return
        try:
            body = json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._json(400, {})
            return
        if set(body) != {"ItemIds", "StartPositionTicks"} or body["ItemIds"] != [ITEM]:
            self._json(400, {})
            return
        state = self.server.fixture
        state.item = ITEM
        state.position = body["StartPositionTicks"] // 10_000_000
        state.effects += 1
        state.calls.append(("POST", self.path))
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()


class JellyfinFixture:
    def __init__(self):
        self.item = None
        self.position = 0
        self.effects = 0
        self.calls = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), _Jellyfin)
        self.server.fixture = self
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def host(self):
        return "127.0.0.1", self.server.server_port

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


class JellyfinPlaybackBackend:
    def __init__(self, fixture):
        self.fixture = fixture
        self.revision = 20

    def _request(self, method, path, body=None):
        raw = None if body is None else json.dumps(body).encode()
        connection = http.client.HTTPConnection(*self.fixture.host, timeout=3)
        try:
            connection.request(method, path, body=raw, headers={
                "X-Emby-Token": TOKEN,
                "Content-Type": "application/json",
            })
            response = connection.getresponse()
            payload = response.read(65_537)
            if len(payload) > 65_536 or response.status not in {200, 204}:
                raise RuntimeError("owned_jellyfin_protocol_failed")
            return None if not payload else json.loads(payload)
        finally:
            connection.close()

    def read_media_playback(self, authority, *, deadline, gate):
        if authority.itemId != ITEM or gate() is not True:
            raise RuntimeError("owned_jellyfin_authority_changed")
        sessions = self._request("GET", "/Sessions")
        if gate() is not True or not isinstance(sessions, list) or len(sessions) != 1:
            raise RuntimeError("owned_jellyfin_readback_failed")
        session = sessions[0]
        current = session.get("NowPlayingItem")
        return MediaPlaybackReadback(
            playbackRevision=self.revision,
            targets=[MediaPlaybackTarget(
                targetId=TARGET,
                targetRevision=self.revision,
                name="Living room",
                available=True,
                currentItemId=None if current is None else current.get("Id"),
                positionSeconds=session["PlayState"]["PositionTicks"] // 10_000_000,
                qualityObservation=None,
            )],
        )

    def execute_media_playback(self, action, *, deadline, gate):
        before = self.read_media_playback(action, deadline=deadline, gate=gate)
        target = before.targets[0]
        if (target.targetId != action.targetId
                or target.targetRevision != action.expectedTargetRevision
                or before.playbackRevision != action.expectedPlaybackRevision
                or gate() is not True):
            raise RuntimeError("owned_jellyfin_authority_changed")
        self._request("POST", "/Sessions/" + "c" * 32 + "/Playing", {
            "ItemIds": [action.itemId],
            "StartPositionTicks": action.startSeconds * 10_000_000,
        })
        if gate() is not True:
            raise RuntimeError("owned_jellyfin_effect_unknown")
        after = self._request("GET", "/Sessions")[0]
        if (after.get("NowPlayingItem", {}).get("Id") != action.itemId
                or after["PlayState"]["PositionTicks"]
                != action.startSeconds * 10_000_000):
            raise RuntimeError("owned_jellyfin_effect_unknown")
        self.revision += 1
        return MediaPlaybackWorkerResult(
            state="succeeded",
            playbackRevision=self.revision,
            target=MediaPlaybackTarget(
                targetId=TARGET,
                targetRevision=self.revision,
                name="Living room",
                available=True,
                currentItemId=action.itemId,
                positionSeconds=action.startSeconds,
                qualityObservation=None,
            ),
        )


def main():
    repository = Path(__file__).resolve().parents[3]
    fixture = JellyfinFixture()
    backend = JellyfinPlaybackBackend(fixture)
    with tempfile.TemporaryDirectory(prefix="larenor-f22-client-") as root:
        state = Path(root) / "client-state.json"
        session = Path(root) / "client-session.json"
        current = archive_result = None
        source = None
        try:
            for phase in ("prepare", "restart"):
                generator = core_fixture.__wrapped__(Path(root))
                server = next(generator)
                app, _client, _settings, clock = server
                try:
                    if phase == "prepare":
                        (_pair, installation, current, _reader,
                         archive_worker, _body) = configured(server)
                        archive_result = archive_worker.result
                        jellyfin = next(
                            item for item in current.sources
                            if item.serviceId == "jellyfin")
                        source = {
                            "now": NOW,
                            "startsAt": NOW - 10,
                            "page": {
                                "schemaVersion": 1,
                                "installationId": installation["id"],
                                "installationRevision": installation["revision"],
                                "snapshotRevision": current.snapshotRevision,
                                "jellyfinServiceRevision": jellyfin.serviceRevision,
                                "offset": 0,
                                "nextOffset": None,
                                "total": 1,
                                "items": [{
                                    "itemId": ITEM,
                                    "mediaKey": "movie:tmdb:603",
                                    "title": "The Matrix",
                                    "mediaKind": "movie",
                                    "runtimeSeconds": 60,
                                }],
                            },
                        }
                    else:
                        clock.now = NOW + 55
                        app.state.core.media_archive_health.binding_reader = BindingReader([current])
                        app.state.core.media_archive_health.backend = Worker(archive_result)
                    app.state.core.media_playback.backend = backend
                    with InstalledCoreTcp(app) as tcp:
                        if phase == "restart":
                            stored = json.loads(session.read_text())
                            stored["baseUrl"] = f"http://127.0.0.1:{tcp.port}"
                            session.write_text(json.dumps(stored))
                        result = subprocess.run(
                            ["flutter", "test", "test/features/server/"
                             "personal_channels/"
                             "server_personal_channel_normal_core_test.dart"],
                            cwd=repository,
                            env={
                                **os.environ,
                                "LARENOR_F22_CORE_URL":
                                    f"http://127.0.0.1:{tcp.port}",
                                "LARENOR_F22_PHASE": phase,
                                "LARENOR_F22_STATE_FILE": str(state),
                                "LARENOR_F22_SESSION_FILE": str(session),
                                "LARENOR_F22_SOURCE": json.dumps(source),
                            },
                            check=False,
                        )
                    if result.returncode:
                        return result.returncode
                finally:
                    generator.close()
            if fixture.effects != 2:
                raise RuntimeError("personal_channel_effect_count_invalid")
            if [method for method, _path in fixture.calls].count("POST") != 2:
                raise RuntimeError("personal_channel_provider_write_invalid")
            return 0
        finally:
            fixture.close()


if __name__ == "__main__":
    sys.exit(main())
