"""Owned TCP/WebSocket Home Assistant fixture for the F47 acceptance gate."""

import base64
import hashlib
import json
import struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread


class FroniusHomeAssistantFixture:
    token = "f47-synthetic-ha-token"
    entity = "number.gen24_battery_minimum_reserve"

    def __init__(self):
        self.percent = 20
        self.updated = "2026-09-05T12:00:00+00:00"
        self.calls = []
        self.errors = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def _reply(self, value, status=200):
                raw = json.dumps(value, separators=(",", ":")).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                try:
                    if self.path == "/api/websocket":
                        owner.calls.append(("WS", self.path))
                        self._websocket()
                        return
                    assert self.headers["Authorization"] == "Bearer " + owner.token
                    assert self.path == "/api/states/" + owner.entity
                    owner.calls.append(("GET", self.path))
                    self._reply({
                        "entity_id": owner.entity,
                        "state": str(owner.percent),
                        "last_updated": owner.updated,
                        "attributes": {
                            "min": 0,
                            "max": 100,
                            "step": 1,
                            "unit_of_measurement": "%",
                        },
                    })
                except Exception as error:  # pragma: no cover - runner surfaces it
                    owner.errors.append(type(error).__name__)
                    self._reply({}, 503)

            def do_POST(self):
                try:
                    assert self.headers["Authorization"] == "Bearer " + owner.token
                    assert self.path == "/api/services/number/set_value"
                    length = int(self.headers["Content-Length"])
                    body = json.loads(self.rfile.read(length))
                    assert body == {"entity_id": owner.entity, "value": 40}
                    owner.calls.append(("POST", self.path))
                    owner.percent = 40
                    owner.updated = "2026-09-05T12:00:01+00:00"
                    self._reply([])
                except Exception as error:  # pragma: no cover - runner surfaces it
                    owner.errors.append(type(error).__name__)
                    self._reply({}, 503)

            def _websocket(self):
                key = self.headers["Sec-WebSocket-Key"]
                accept = base64.b64encode(hashlib.sha1(
                    (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
                ).digest()).decode()
                self.send_response(101, "Switching Protocols")
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.send_header("Sec-WebSocket-Accept", accept)
                self.end_headers()
                self._write({"type": "auth_required"})
                assert self._read() == {
                    "type": "auth", "access_token": owner.token,
                }
                self._write({"type": "auth_ok"})
                assert self._read() == {
                    "id": 1, "type": "config/entity_registry/list",
                }
                self._write({
                    "id": 1,
                    "type": "result",
                    "success": True,
                    "result": [{
                        "entity_id": owner.entity,
                        "platform": "fronius",
                        "config_entry_id": "entry_1",
                        "device_id": "device_1",
                        "unique_id": (
                            "gen24-fixture-modbus-battery_minimum_reserve"
                        ),
                        "disabled_by": None,
                    }],
                })
                assert self._read() == {
                    "id": 2, "type": "config/device_registry/list",
                }
                self._write({
                    "id": 2,
                    "type": "result",
                    "success": True,
                    "result": [{
                        "id": "device_1",
                        "config_entries": ["entry_1"],
                        "manufacturer": "Fronius International GmbH",
                        "model": "GEN24 Plus",
                    }],
                })
                opcode, payload = self._read_raw()
                assert opcode == 8 and payload == b""
                self._write_raw(8, b"")
                self.close_connection = True

            def _exact(self, count):
                result = bytearray()
                while len(result) < count:
                    part = self.rfile.read(count - len(result))
                    if not part:
                        raise EOFError
                    result.extend(part)
                return bytes(result)

            def _read_raw(self):
                first, second = self._exact(2)
                assert first & 0x80 and second & 0x80
                length = second & 0x7f
                if length == 126:
                    length = struct.unpack("!H", self._exact(2))[0]
                mask = self._exact(4)
                raw = self._exact(length)
                return first & 0x0f, bytes(
                    value ^ mask[index % 4] for index, value in enumerate(raw)
                )

            def _read(self):
                opcode, raw = self._read_raw()
                assert opcode == 1
                return json.loads(raw)

            def _write_raw(self, opcode, raw):
                header = (
                    bytes((0x80 | opcode, len(raw)))
                    if len(raw) < 126
                    else bytes((0x80 | opcode, 126))
                    + struct.pack("!H", len(raw))
                )
                self.wfile.write(header + raw)
                self.wfile.flush()

            def _write(self, value):
                self._write_raw(
                    1, json.dumps(value, separators=(",", ":")).encode()
                )

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = Thread(
            target=self.server.serve_forever,
            name="f47-ha-fixture",
            daemon=True,
        )
        self.thread.start()

    @property
    def base_url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    @property
    def post_count(self):
        return sum(method == "POST" for method, _path in self.calls)

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


__all__ = ["FroniusHomeAssistantFixture"]
