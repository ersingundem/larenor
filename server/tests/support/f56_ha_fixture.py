"""Actual local TCP/WebSocket HA contract; production Core adapters are retained."""
import base64
import hashlib
import json
import struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread


class BroadlinkFixture:
    token = "f56-synthetic-only-token"
    entity = "remote.living_room_broadlink"
    def __init__(self):
        self.calls, self.errors = [], []
        owner = self
        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            def log_message(self, *_): pass
            def reply(self, value, status=200):
                raw = json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers(); self.wfile.write(raw)
            def do_GET(self):
                try:
                    owner.calls.append(("GET", self.path, None))
                    if self.path == "/api/websocket":
                        self.websocket(); return
                    assert self.headers["Authorization"] == "Bearer " + owner.token
                    assert self.path == "/api/states/" + owner.entity
                    self.reply({"entity_id": owner.entity, "state": "on",
                        "attributes": {"supported_features": 3},
                        "last_updated": "2026-09-30T12:00:00+00:00"})
                except Exception as error:
                    owner.errors.append(type(error).__name__); self.reply({}, 503)
            def do_POST(self):
                try:
                    assert self.headers["Authorization"] == "Bearer " + owner.token
                    assert self.path in {
                        "/api/services/remote/send_command",
                        "/api/services/remote/learn_command",
                    }
                    body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    if self.path.endswith("/send_command"):
                        assert body == {"entity_id": owner.entity, "device": "television",
                            "command": "louder", "num_repeats": 1, "delay_secs": .4}
                    else:
                        assert body == {"entity_id": owner.entity, "device": "television",
                            "command": "louder", "command_type": "ir", "alternative": False}
                    owner.calls.append(("POST", self.path, body)); self.reply([])
                except Exception as error:
                    owner.errors.append(type(error).__name__); self.reply({}, 503)
            def websocket(self):
                accept = base64.b64encode(hashlib.sha1((self.headers["Sec-WebSocket-Key"]
                    + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                self.send_response(101, "Switching Protocols")
                self.send_header("Upgrade", "websocket"); self.send_header("Connection", "Upgrade")
                self.send_header("Sec-WebSocket-Accept", accept); self.end_headers()
                def write(value, opcode=1):
                    raw = (json.dumps(value).encode() if opcode == 1 else value)
                    header = bytes((0x80 | opcode, len(raw))) if len(raw) < 126 else bytes((0x80 | opcode, 126)) + struct.pack("!H", len(raw))
                    self.wfile.write(header + raw); self.wfile.flush()
                def read_frame():
                    first, second = self.rfile.read(2)
                    assert first & 0x80 and not first & 0x70 and second & 0x80
                    length = second & 0x7f
                    if length == 126: length = struct.unpack("!H", self.rfile.read(2))[0]
                    mask, raw = self.rfile.read(4), self.rfile.read(length)
                    return first & 0x0f, bytes(value ^ mask[i % 4] for i, value in enumerate(raw))
                def read():
                    opcode, raw = read_frame()
                    assert opcode == 1
                    return json.loads(raw)
                write({"type": "auth_required"})
                assert read() == {"type": "auth", "access_token": owner.token}
                write({"type": "auth_ok"})
                assert read() == {"id": 1, "type": "config/entity_registry/list"}
                write({"id": 1, "type": "result", "success": True, "result": [{
                    "entity_id": owner.entity, "platform": "broadlink", "config_entry_id": "entry_1",
                    "device_id": "device_1", "unique_id": "broadlink_remote_fixture", "disabled_by": None}]})
                assert read() == {"id": 2, "type": "config/device_registry/list"}
                write({"id": 2, "type": "result", "success": True, "result": [{
                    "id": "device_1", "config_entries": ["entry_1"], "manufacturer": "Broadlink", "model": "RM4 mini"}]})
                opcode, payload = read_frame()
                assert opcode == 8 and payload == b""
                write(b"", opcode=8)
                self.close_connection = True
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"
    def close(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=2)
