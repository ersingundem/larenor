"""Bounded Home Assistant TCP/WebSocket fixture for F50 acceptance."""

import base64
from datetime import datetime, timezone
import hashlib
import json
import struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread


class ComfortHomeAssistantFixture:
    token = "synthetic-ha-token"

    def __init__(self, now_seconds):
        self.climate = "off"
        self.now_seconds = now_seconds
        self.mutation_count = 0
        self.calls = []
        self.errors = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def _send(self, value):
                body = json.dumps(value, separators=(",", ":")).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                try:
                    length = int(self.headers.get("content-length", "0"))
                    body = json.loads(self.rfile.read(length))
                    owner.calls.append(("POST", self.path))
                    assert self.headers["Authorization"] == "Bearer " + owner.token
                    assert self.path == "/api/services/climate/set_hvac_mode"
                    assert body == {
                        "entity_id": "climate.living_room",
                        "hvac_mode": "heat",
                    }
                    owner.mutation_count += 1
                    owner.climate = "heat"
                    self._send([])
                except Exception as error:  # pragma: no cover - surfaced by runner
                    owner.errors.append(type(error).__name__)
                    self.send_error(503)

            def do_GET(self):
                try:
                    owner.calls.append(("GET", self.path))
                    if self.path == "/api/websocket":
                        self._websocket()
                        return
                    assert self.headers["Authorization"] == "Bearer " + owner.token
                    assert self.path.startswith("/api/states/")
                    entity = self.path.removeprefix("/api/states/")
                    state, attributes = {
                        "sensor.living_temperature": (
                            "19", {"unit_of_measurement": "°C"}),
                        "sensor.living_humidity": (
                            "50", {"unit_of_measurement": "%"}),
                        "sensor.living_co2": (
                            "700", {"unit_of_measurement": "ppm"}),
                        "sensor.living_voc": (
                            "200", {"unit_of_measurement": "ppb"}),
                        "binary_sensor.living_smoke": (
                            "off", {"device_class": "smoke"}),
                        "binary_sensor.living_occupancy": (
                            "on", {"device_class": "occupancy"}),
                        "cover.living_room_window": (
                            "closed", {"supported_features": 3}),
                        "weather.home": (
                            "sunny", {
                                "temperature": 12,
                                "temperature_unit": "°C",
                            }),
                        "sensor.outdoor_aqi": (
                            "40", {"unit_of_measurement": "AQI"}),
                    }.get(entity, (None, None))
                    if entity == "climate.living_room":
                        state, attributes = owner.climate, {
                            "hvac_modes": ["off", "heat", "cool", "fan_only"],
                        }
                    assert state is not None
                    offset = 0 if owner.climate == "heat" else -1
                    stamp = datetime.fromtimestamp(
                        owner.now_seconds + offset, tz=timezone.utc
                    ).isoformat()
                    self._send({
                        "entity_id": entity,
                        "state": state,
                        "attributes": attributes,
                        "last_updated": stamp,
                    })
                except Exception as error:  # pragma: no cover - surfaced by runner
                    owner.errors.append(type(error).__name__)
                    self.send_error(503)

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
                self._write_frame({"type": "auth_required"})
                assert self._read_frame() == {
                    "type": "auth", "access_token": owner.token,
                }
                self._write_frame({"type": "auth_ok"})
                assert self._read_frame() == {
                    "id": 1, "type": "config/entity_registry/list",
                }
                entities = [
                    "weather.home", "sensor.outdoor_aqi",
                    "climate.living_room", "cover.living_room_window",
                    "sensor.living_temperature", "sensor.living_humidity",
                    "sensor.living_co2", "sensor.living_voc",
                    "binary_sensor.living_smoke",
                    "binary_sensor.living_occupancy",
                ]
                self._write_frame({
                    "id": 1,
                    "type": "result",
                    "success": True,
                    "result": [{
                        "entity_id": entity,
                        "disabled_by": None,
                        "hidden_by": None,
                    } for entity in entities],
                })

            def _read_exact(self, count):
                value = bytearray()
                while len(value) < count:
                    part = self.rfile.read(count - len(value))
                    if not part:
                        raise EOFError
                    value.extend(part)
                return bytes(value)

            def _read_frame(self):
                _first, second = self._read_exact(2)
                length = second & 0x7f
                if length == 126:
                    length = struct.unpack("!H", self._read_exact(2))[0]
                mask = self._read_exact(4)
                payload = self._read_exact(length)
                return json.loads(bytes(
                    child ^ mask[index % 4]
                    for index, child in enumerate(payload)
                ))

            def _write_frame(self, value):
                payload = json.dumps(value, separators=(",", ":")).encode()
                header = (
                    bytes((0x81, len(payload)))
                    if len(payload) < 126
                    else b"\x81\x7e" + struct.pack("!H", len(payload))
                )
                self.wfile.write(header + payload)
                self.wfile.flush()

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def base_url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.thread.join(timeout=5)
        self.server.server_close()


__all__ = ["ComfortHomeAssistantFixture"]
