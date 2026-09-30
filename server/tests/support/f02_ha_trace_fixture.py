"""Real-shaped loopback Home Assistant automation trace fixture."""

import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import struct
import threading


ENTITY = "automation.welcome_home"
ITEM_ID = "welcome_home_rule"
RUN_ID = "a" * 32
CONTEXT_ID = "b" * 32
START = "2026-09-05T11:59:00+00:00"
FINISH = "2026-09-05T11:59:01+00:00"


class HomeAssistantTraceFixture:
    def __init__(self):
        self.websocket_calls = 0
        self.trace_list_calls = 0
        self.trace_get_calls = 0
        self.registry_platform = "automation"
        self.trace_supported = True
        self.after_trace_list = None
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
                if self.path == "/api/websocket":
                    return self.websocket()
                assert self.headers["Authorization"] == "Bearer trace-loopback-only"
                if self.path == "/api/states/" + ENTITY:
                    return self.reply_json({
                        "entity_id": ENTITY,
                        "state": "on",
                        "attributes": {"secret": "NEVER-PUBLISH-TRACE-ATTRIBUTE"},
                        "last_changed": START,
                    })
                self.reply_json({}, 404)

            def websocket(self):
                fixture.websocket_calls += 1
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
                    if first == 0x88:
                        return None
                    assert first == 0x81 and second & 0x80
                    length = second & 0x7f
                    if length == 126:
                        length = struct.unpack("!H", self.rfile.read(2))[0]
                    mask, raw = self.rfile.read(4), self.rfile.read(length)
                    return json.loads(bytes(
                        value ^ mask[index % 4] for index, value in enumerate(raw)
                    ))

                summary = {
                    "last_step": "action/0",
                    "run_id": RUN_ID,
                    "state": "stopped",
                    "script_execution": "finished",
                    "timestamp": {"start": START, "finish": FINISH},
                    "domain": "automation",
                    "item_id": ITEM_ID,
                }
                write({"type": "auth_required"})
                assert read() == {
                    "type": "auth", "access_token": "trace-loopback-only",
                }
                write({"type": "auth_ok"})
                request = read()
                assert request == {"id": 1, "type": "config/entity_registry/list"}
                write({"id": 1, "type": "result", "success": True, "result": [{
                    "entity_id": ENTITY,
                    "platform": fixture.registry_platform,
                    "unique_id": ITEM_ID,
                    "disabled_by": None,
                }]})
                request = read()
                assert request == {
                    "id": 2, "type": "trace/list",
                    "domain": "automation", "item_id": ITEM_ID,
                }
                fixture.trace_list_calls += 1
                if not fixture.trace_supported:
                    write({"id": 2, "type": "result", "success": False,
                           "error": {"code": "unknown_command",
                                     "message": "Unknown command."}})
                    return
                write({"id": 2, "type": "result", "success": True,
                       "result": [summary]})
                if fixture.after_trace_list is not None:
                    callback, fixture.after_trace_list = fixture.after_trace_list, None
                    callback()
                request = read()
                if request is None:
                    return
                assert request == {
                    "id": 3, "type": "trace/get", "domain": "automation",
                    "item_id": ITEM_ID, "run_id": RUN_ID,
                }
                fixture.trace_get_calls += 1
                write({"id": 3, "type": "result", "success": True, "result": {
                    **summary,
                    "context": {
                        "id": CONTEXT_ID, "parent_id": None, "user_id": None,
                    },
                    "trace": {"action/0": [{
                        "path": "action/0",
                        "changed_variables": {"private": "NEVER-PUBLISH-TRACE"},
                    }]},
                    "config": {"private": "NEVER-PUBLISH-CONFIG"},
                    "blueprint_inputs": None,
                }})
                self.close_connection = True

        self.http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.http.server_port}"

    def close(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join(timeout=2)
