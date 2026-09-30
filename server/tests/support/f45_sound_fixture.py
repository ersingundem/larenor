"""Real TCP/WS HA and Frigate fixture for F45 normal-Core acceptance."""

import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import struct
import threading
from urllib.parse import parse_qs, urlsplit


class SoundFixture:
    def __init__(self):
        self.calls, self.errors = [], []
        self.token = "f45-synthetic-only-token"
        self.frigate_credentials = None
        self.registry_platform = "frigate"
        self.device = "c" * 32
        self.allowed = ["front", "back"]
        self.semantic = True
        self.during = None
        self.audio_enabled = True
        self.available = True
        self.listen = ["bark", "fire_alarm"]
        self.reviews = [self.review("1788609600-front", "front")]
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_):
                pass

            def reply(self, body, status=200, content_type="application/json"):
                raw = body if type(body) is bytes else json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                try:
                    owner.calls.append(("GET", self.path))
                    path = urlsplit(self.path).path
                    if path == "/api/version":
                        self.reply(b"0.17.0-f45-v1", content_type="text/plain")
                        return
                    if path == "/api/websocket":
                        self.websocket()
                        return
                    if not owner.available:
                        self.reply({}, status=503)
                        return
                    assert self.headers["Authorization"] == "Bearer " + owner.token
                    if path == "/api/":
                        self.reply({"message": "API running."})
                        return
                    if path.startswith("/api/states/"):
                        entity = path.removeprefix("/api/states/")
                        assert entity in {"camera.front", "camera.back"}
                        self.reply({"entity_id": entity, "state": "streaming", "attributes": {},
                                    "last_updated": "2026-09-05T12:00:00+00:00",
                                    "context": {"id": "fixture", "user_id": None, "parent_id": None}})
                        return
                    if path == "/api/profile":
                        self.reply({"username": "fixture", "role": "admin", "allowed_cameras": owner.allowed})
                        return
                    if path == "/api/config":
                        self.reply({"cameras": {name: {"audio": {
                            "enabled": owner.audio_enabled, "listen": owner.listen,
                        }} for name in ("front", "back")}, "semantic_search": {"enabled": True}})
                        return
                    if owner.during is not None:
                        callback, owner.during = owner.during, None
                        callback()
                    if path == "/api/review":
                        query = parse_qs(urlsplit(self.path).query)
                        assert query["cameras"] == ["front"] and int(query["limit"][0]) <= 64
                        after, before = float(query["after"][0]), float(query["before"][0])
                        self.reply([item for item in owner.reviews
                                    if after <= item["start_time"] <= before])
                        return
                    if path.startswith("/api/review/"):
                        identity = path.removeprefix("/api/review/")
                        item = next((item for item in owner.reviews if item["id"] == identity), None)
                        self.reply(item or {}, status=200 if item else 404)
                        return
                    raise AssertionError("unexpected_path")
                except Exception as error:
                    owner.errors.append(repr(error))
                    self.reply({}, status=503)

            def do_POST(self):
                owner.calls.append(("POST", self.path))
                self.reply({}, status=405)

            def websocket(self):
                accept = base64.b64encode(hashlib.sha1((self.headers["Sec-WebSocket-Key"]
                    + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                self.send_response(101, "Switching Protocols")
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.send_header("Sec-WebSocket-Accept", accept)
                self.end_headers()

                def write(value):
                    raw = json.dumps(value).encode()
                    header = bytes([0x81, len(raw)]) if len(raw) < 126 else b"\x81\x7e" + struct.pack("!H", len(raw))
                    self.wfile.write(header + raw)
                    self.wfile.flush()

                def read():
                    first, second = self.rfile.read(2)
                    assert first == 0x81 and second & 0x80
                    length = second & 0x7F
                    if length == 126:
                        length = struct.unpack("!H", self.rfile.read(2))[0]
                    mask, raw = self.rfile.read(4), self.rfile.read(length)
                    return json.loads(bytes(value ^ mask[index % 4] for index, value in enumerate(raw)))

                write({"type": "auth_required"})
                assert read() == {"type": "auth", "access_token": owner.token}
                write({"type": "auth_ok"})
                assert read() == {"id": 1, "type": "config/entity_registry/list"}
                write({"id": 1, "type": "result", "success": True, "result": [{
                    "entity_id": "camera." + name, "platform": owner.registry_platform,
                    "config_entry_id": "b" * 32, "device_id": owner.device,
                    "unique_id": "b" * 32 + ":camera:" + name, "disabled_by": None,
                } for name in ("front", "back")]})
                self.close_connection = True

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    @staticmethod
    def review(identity, camera):
        return {"id": identity, "camera": camera, "start_time": 1788609600.0,
                "end_time": 1788609608.0, "severity": "alert",
                "data": {"audio": ["bark", "fire_alarm"], "objects": []}}

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
