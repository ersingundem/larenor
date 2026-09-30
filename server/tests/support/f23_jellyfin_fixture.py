"""Bounded loopback Jellyfin 10.11 Live TV fixture for F23 acceptance."""

from datetime import datetime, timezone
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class JellyfinLiveTvFixture:
    program_id = "1" * 32
    channel_id = "2" * 32
    server_id = "3" * 32
    token = "jellyfin-live-tv-test-token"

    def __init__(self, now):
        self.calls = []
        self.timers = {}
        self.recordings = []
        self.sequence = 0
        self.drop_next_create_response = False
        self.drop_next_cancel_response = False
        self.start = int(now) - 600
        self.end = int(now) + 3600
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def _reply(self, status, value=None):
                body = b"" if value is None else json.dumps(value).encode()
                self.send_response(status)
                if value is not None:
                    self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                if body:
                    self.wfile.write(body)

            def _authenticated(self):
                return self.headers.get("X-Emby-Token") == owner.token

            def do_GET(self):
                owner.calls.append(("GET", self.path))
                if not self._authenticated():
                    return self._reply(401, {})
                if self.path == "/System/Info":
                    return self._reply(200, {
                        "ProductName": "Jellyfin Server", "Version": "10.11.1",
                        "Id": owner.server_id, "StartupWizardCompleted": True,
                    })
                if self.path == "/LiveTv/Info":
                    return self._reply(200, {"IsEnabled": True})
                if self.path.startswith("/LiveTv/Programs?"):
                    return self._reply(200, {
                        "Items": [owner.programme()], "TotalRecordCount": 1,
                    })
                if self.path == (
                        "/LiveTv/Timers/Defaults?programId=" + owner.program_id):
                    return self._reply(200, owner.timer_defaults())
                if self.path == "/LiveTv/Timers":
                    return self._reply(200, {
                        "Items": list(owner.timers.values()),
                        "TotalRecordCount": len(owner.timers),
                    })
                if self.path.startswith("/LiveTv/Timers/"):
                    timer = owner.timers.get(self.path.rsplit("/", 1)[1])
                    return self._reply(404 if timer is None else 200, timer or {})
                if self.path.startswith("/LiveTv/Recordings?"):
                    query = parse_qs(urlsplit(self.path).query)
                    recordings = owner.recordings
                    if query.get('isInProgress') == ['true']:
                        recordings = [item for item in recordings if item.get('Status') == 'InProgress']
                    return self._reply(200, {
                        "Items": recordings,
                        "TotalRecordCount": len(recordings),
                    })
                return self._reply(404, {})

            def do_POST(self):
                owner.calls.append(("POST", self.path))
                if not self._authenticated() or self.path != "/LiveTv/Timers":
                    return self._reply(
                        401 if not self._authenticated() else 404, {}
                    )
                body = json.loads(
                    self.rfile.read(int(self.headers["Content-Length"]))
                )
                owner.sequence += 1
                timer_id = f"timer-{owner.sequence}"
                owner.timers[timer_id] = body | {
                    "Id": timer_id, "Status": "New", "RunTimeTicks": 0,
                }
                if owner.drop_next_create_response:
                    owner.drop_next_create_response = False
                    self.close_connection = True
                    return
                self._reply(204)

            def do_DELETE(self):
                owner.calls.append(("DELETE", self.path))
                if (not self._authenticated()
                        or not self.path.startswith("/LiveTv/Timers/")):
                    return self._reply(
                        401 if not self._authenticated() else 404, {}
                    )
                owner.timers.pop(self.path.rsplit("/", 1)[1], None)
                for item in owner.recordings:
                    if item.get('TimerId') == self.path.rsplit('/',1)[1]:
                        item['Status'] = 'Cancelled'
                if owner.drop_next_cancel_response:
                    owner.drop_next_cancel_response = False
                    self.close_connection = True
                    return
                self._reply(204)

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._thread = threading.Thread(
            target=self._server.serve_forever, daemon=True
        )
        self._thread.start()
        self.url = f"http://127.0.0.1:{self._server.server_port}"

    @staticmethod
    def _instant(value):
        return datetime.fromtimestamp(value, timezone.utc).isoformat().replace(
            "+00:00", "Z"
        )

    def programme(self):
        return {
            "Id": self.program_id, "ChannelId": self.channel_id,
            "ChannelName": "Fixture News", "Name": "Morning News",
            "StartDate": self._instant(self.start),
            "EndDate": self._instant(self.end),
        }

    def timer_defaults(self):
        return self.programme() | {
            "ProgramId": self.program_id,
            "Overview": "Fixture programme", "ServiceName": "Default",
        }

    def close(self):
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=2)
