"""Loopback Home Assistant/OpenEPaperLink fixture for F58."""

import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import struct
import threading

JPEG = base64.b64decode("/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAABKKADAAQAAAABAAAAgAAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAgAEoAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAE//aAAwDAQACEQMRAD8A/n/ooooA/v8AKKKKAP4A6KKKAP7/ACiiigD+AOiiigD+/wAooooA/gDooooA/v8AKKKKAP4A6KKKAP7/ACiiigD+AOiiigD+/wAooooA/gDooooA/v8AKKKKAP4A6KKKAP7/ACiiigD+AOiiigD+/wAooooA/gDooooA/9D9/KKKKAP4A6KKKAP7/KKKKAP4A6KKKAP7/KKKKAP4A6KKKAP7/KKKKAP4A6KKKAP7/KKKKAP4A6KKKAP7/KKKKAP4A6KKKAP7/KKKKAP4A6KKKAP7/KKKKAP4A6KKKAP7/KKKKAP/0f5/6KKKAP7/ACiiigD+AOiiigD+/wAooooA/gDooooA/v8AKKKKAP4A6KKKAP7/ACiiigD+AOiiigD+/wAooooA/gDooooA/v8AKKKKAP4A6KKKAP7/ACiiigD+AOiiigD+/wAooooA/gDooooA/v8AKKKKAP4A6KKKAP/S/fyiiigD+AOiiigD+/yiiigD+AOiiigD+/yiiigD+AOiiigD+/yiiigD+AOiiigD+/yiiigD+AOiiigD+/yiiigD+AOiiigD+/yiiigD+AOiiigD+/yiiigD+AOiiigD+/yiiigD+AOiiigD+/yiiigD/9P+f+iiigD+/wAooooA/gDooooA/v8AKKKKAP4A6KKKAP7/ACiiigD+AOiiigD+/wAooooA/gDooooA/v8AKKKKAP4A6KKKAP7/ACiiigD+AOiiigD+/wAooooA/gDooooA/v8AKKKKAP4A6KKKAP7/ACiiigD+AOiiigD/1P38ooooA/gDooooA/v8ooooA/gDooooA/v8ooooA/gDooooA/v8ooooA/gDooooA/v8ooooA/gDooooA/v8ooooA/gDooooA/v8ooooA/gDooooA/v8ooooA/gDooooA/v8ooooA/gDooooA/v8ooooA//V/n/ooooA/v8AKKKKAP4A6KKKAP7/ACiiigD+AOiiigD+/wAooooA/gDooooA/v8AKKKKAP4A6KKKAP7/ACiiigD+AOiiigD+/wAooooA/gDooooA/v8AKKKKAP4A6KKKAP7/ACiiigD+AOiiigD+/wAooooA/gDooooA/9b9/KKKKAP4A6KKKAP7/KKKKAP4A6KKKAP7/KKKKAP4A6KKKAP7/KKKKAP4A6KKKAP7/KKKKAP4A6KKKAP7/KKKKAP4A6KKKAP7/KKKKAP4A6KKKAP7/KKKKAP4A6KKKAP7/KKKKAP/2Q==")
DEVICE = "d" * 32
IMAGE = "image.hall_display_content"


class OpenEpaperLinkFixture:
    def __init__(self):
        self.calls = []
        self.real_sends = 0
        self.dry_runs = 0
        self.drop_real_response = False
        self.registry_platform = "open_epaper_link"
        self.image = JPEG
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def reply_json(self, value, status=200):
                raw = json.dumps(value, separators=(",", ":")).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                fixture.calls.append(("GET", self.path))
                if self.path == "/api/websocket":
                    self.websocket()
                    return
                assert self.headers["Authorization"] == "Bearer oepl-loopback-only"
                if self.path == "/api/states":
                    self.reply_json([
                        {"entity_id": IMAGE, "state": "2026-09-30T12:00:00+00:00", "attributes": {}},
                        {"entity_id": "sensor.hall_width", "state": "296", "attributes": {}},
                        {"entity_id": "sensor.hall_height", "state": "128", "attributes": {}},
                        {"entity_id": "sensor.hall_battery", "state": "82", "attributes": {}},
                        {"entity_id": "sensor.hall_last_seen", "state": "2026-09-30T11:59:00+00:00", "attributes": {}},
                        {"entity_id": "sensor.hall_pending", "state": "0", "attributes": {}},
                        {"entity_id": "sensor.hall_updates", "state": str(fixture.real_sends), "attributes": {}},
                    ])
                    return
                if self.path == "/api/image_proxy/" + IMAGE:
                    self.send_response(200)
                    self.send_header("Content-Type", "image/jpeg")
                    self.send_header("Content-Length", str(len(fixture.image)))
                    self.end_headers()
                    self.wfile.write(fixture.image)
                    return
                self.reply_json({}, 404)

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
                    header = bytes([0x81, len(raw)]) if len(raw) < 126 else b"\x81\x7e" + struct.pack("!H", len(raw))
                    self.wfile.write(header + raw)
                    self.wfile.flush()

                def read():
                    first, second = self.rfile.read(2)
                    assert first == 0x81 and second & 0x80
                    length = second & 0x7f
                    if length == 126:
                        length = struct.unpack("!H", self.rfile.read(2))[0]
                    mask, raw = self.rfile.read(4), self.rfile.read(length)
                    return json.loads(bytes(value ^ mask[index % 4] for index, value in enumerate(raw)))

                write({"type": "auth_required"})
                assert read() == {"type": "auth", "access_token": "oepl-loopback-only"}
                write({"type": "auth_ok"})
                request = read()
                assert request == {"id": 1, "type": "config/entity_registry/list"}
                entities = [
                    (IMAGE, "aa_display_content"),
                    ("sensor.hall_width", "aa_width"),
                    ("sensor.hall_height", "aa_height"),
                    ("sensor.hall_battery", "aa_battery_percentage"),
                    ("sensor.hall_last_seen", "aa_last_seen"),
                    ("sensor.hall_pending", "aa_pending_updates"),
                    ("sensor.hall_updates", "aa_update_count"),
                ]
                write({"id": 1, "type": "result", "success": True, "result": [
                    {"entity_id": entity, "platform": fixture.registry_platform,
                     "device_id": DEVICE, "unique_id": unique, "disabled_by": None}
                    for entity, unique in entities
                ]})
                request = read()
                assert request == {"id": 2, "type": "config/device_registry/list"}
                write({"id": 2, "type": "result", "success": True, "result": [{
                    "id": DEVICE, "name": "Hall display", "name_by_user": None,
                    "identifiers": [["open_epaper_link", "0011223344556677"]],
                }]})
                self.close_connection = True

            def do_POST(self):
                fixture.calls.append(("POST", self.path))
                assert self.path == "/api/services/open_epaper_link/drawcustom"
                assert self.headers["Authorization"] == "Bearer oepl-loopback-only"
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                assert set(body) == {
                    "device_id", "payload", "background", "rotate", "dither",
                    "ttl", "refresh_type", "dry-run",
                }
                assert body["device_id"] == [DEVICE]
                assert body["background"] == "white" and body["dither"] == 0
                assert all(set(item) <= {"type", "value", "x", "y", "size", "anchor", "fill"}
                           for item in body["payload"])
                if body["dry-run"]:
                    fixture.dry_runs += 1
                else:
                    fixture.real_sends += 1
                    if fixture.drop_real_response:
                        self.close_connection = True
                        return
                self.reply_json([])

        self.http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.http.server_port}"

    def close(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join(timeout=2)

