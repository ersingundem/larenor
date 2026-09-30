"""Real-shaped loopback Home Assistant entity history fixture."""

import base64
from datetime import datetime, timedelta, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import struct
import threading
from urllib.parse import parse_qs, unquote, urlsplit


ENTITY = "binary_sensor.hall_motion"
UNIQUE_ID = "hall-motion-fixture"
TOKEN = "history-loopback-only"


class HomeAssistantHistoryFixture:
    def __init__(self):
        self.history_calls = 0
        self.registry_calls = 0
        self.registry_platform = "mqtt"
        self.unavailable_history = False
        self.after_registry = None
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def json_response(self, value, status=200):
                raw = json.dumps(value, separators=(",", ":")).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                if self.path == "/api/websocket":
                    return self.websocket()
                assert self.headers["Authorization"] == "Bearer " + TOKEN
                parsed = urlsplit(self.path)
                if parsed.path == "/api/states/" + ENTITY:
                    stamp = datetime(2026, 9, 5, 11, 59, tzinfo=timezone.utc)
                    return self.json_response({
                        "entity_id": ENTITY,
                        "state": "on",
                        "attributes": {"private": "NEVER-PUBLISH-STATE"},
                        "last_changed": stamp.isoformat(),
                        "last_updated": stamp.isoformat(),
                    })
                if parsed.path.startswith("/api/history/period/"):
                    fixture.history_calls += 1
                    query = parse_qs(parsed.query)
                    assert query["filter_entity_id"] == [ENTITY]
                    start = datetime.fromisoformat(
                        unquote(parsed.path.rsplit("/", 1)[1]).replace("Z", "+00:00")
                    )
                    end = datetime.fromisoformat(
                        query["end_time"][0].replace("Z", "+00:00")
                    )
                    states = [{
                        "entity_id": ENTITY,
                        "state": "off",
                        "attributes": {
                            "friendly_name": "NEVER-PUBLISH-HISTORY-ATTRIBUTE"
                        },
                        "last_changed": (start - timedelta(minutes=5)).isoformat(),
                        "last_updated": (start - timedelta(minutes=5)).isoformat(),
                    }]
                    state = "off"
                    cursor = start + timedelta(minutes=1)
                    while cursor < end:
                        state = (
                            "unavailable" if fixture.unavailable_history
                            else "on" if state == "off" else "off"
                        )
                        states.append({
                            "entity_id": ENTITY,
                            "state": state,
                            "attributes": {"private": "NEVER-PUBLISH-HISTORY"},
                            "last_changed": cursor.isoformat(),
                            "last_updated": cursor.isoformat(),
                        })
                        cursor += timedelta(minutes=2)
                    return self.json_response([states])
                return self.json_response({}, 404)

            def websocket(self):
                key = self.headers["Sec-WebSocket-Key"]
                accept = base64.b64encode(hashlib.sha1(
                    (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
                ).digest()).decode()
                self.send_response(101, "Switching Protocols")
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.send_header("Sec-WebSocket-Accept", accept)
                self.end_headers()

                def write(value):
                    raw = json.dumps(value, separators=(",", ":")).encode()
                    header = (
                        bytes([0x81, len(raw)]) if len(raw) < 126
                        else b"\x81\x7e" + struct.pack("!H", len(raw))
                    )
                    self.wfile.write(header + raw)
                    self.wfile.flush()

                def read():
                    header = self.rfile.read(2)
                    if len(header) != 2:
                        return None
                    first, second = header
                    assert second & 0x80
                    length = second & 0x7f
                    if length == 126:
                        length = struct.unpack("!H", self.rfile.read(2))[0]
                    mask, raw = self.rfile.read(4), self.rfile.read(length)
                    if first == 0x88:
                        return None
                    assert first == 0x81
                    return json.loads(bytes(
                        value ^ mask[index % 4]
                        for index, value in enumerate(raw)
                    ))

                write({"type": "auth_required"})
                assert read() == {"type": "auth", "access_token": TOKEN}
                write({"type": "auth_ok"})
                request = read()
                assert request == {"id": 1, "type": "config/entity_registry/list"}
                fixture.registry_calls += 1
                write({"id": 1, "type": "result", "success": True, "result": [{
                    "entity_id": ENTITY,
                    "platform": fixture.registry_platform,
                    "unique_id": UNIQUE_ID,
                    "disabled_by": None,
                }]})
                if fixture.after_registry is not None:
                    callback, fixture.after_registry = fixture.after_registry, None
                    callback()
                read()

        self.http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.http.server_port}"

    def close(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join(timeout=2)
