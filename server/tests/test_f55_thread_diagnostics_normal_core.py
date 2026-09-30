"""Normal Core to real loopback Home Assistant WebSocket acceptance for F55."""

import base64
import hashlib
import json
import socket
import struct
import threading

from conftest import auth, ready


TOKEN = "synthetic-thread-only-token"


def _exact(stream, count):
    result = bytearray()
    while len(result) < count:
        part = stream.recv(count - len(result))
        if not part:
            raise EOFError
        result.extend(part)
    return bytes(result)


def _request(stream):
    value = bytearray()
    while b"\r\n\r\n" not in value:
        value.extend(stream.recv(4096))
    head = bytes(value).split(b"\r\n\r\n", 1)[0]
    lines = head.split(b"\r\n")
    headers = {}
    for line in lines[1:]:
        key, child = line.split(b":", 1)
        headers[key.decode().lower()] = child.decode().strip()
    return lines[0].decode(), headers


def _read_json(stream):
    _, second = _exact(stream, 2)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", _exact(stream, 2))[0]
    mask = _exact(stream, 4)
    payload = _exact(stream, length)
    return json.loads(bytes(
        value ^ mask[index % 4] for index, value in enumerate(payload)
    ))


def _write_json(stream, value):
    payload = json.dumps(value, separators=(",", ":")).encode()
    header = (
        bytes((0x81, len(payload)))
        if len(payload) < 126
        else b"\x81\x7e" + struct.pack("!H", len(payload))
    )
    stream.sendall(header + payload)


class _HomeAssistant:
    def __init__(self):
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(2)
        self.url = f"http://127.0.0.1:{self.listener.getsockname()[1]}"
        self.commands = []
        self.failures = []
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        try:
            websocket, _ = self.listener.accept()
            with websocket:
                request, headers = _request(websocket)
                assert request == "GET /api/websocket HTTP/1.1"
                accept = base64.b64encode(hashlib.sha1(
                    (headers["sec-websocket-key"]
                     + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
                ).digest()).decode()
                websocket.sendall((
                    "HTTP/1.1 101 Switching Protocols\r\n"
                    "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                    f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
                ).encode())
                _write_json(websocket, {"type": "auth_required"})
                authenticated = _read_json(websocket)
                self.commands.append(authenticated)
                assert authenticated == {"type": "auth", "access_token": TOKEN}
                _write_json(websocket, {"type": "auth_ok"})

                datasets = _read_json(websocket)
                self.commands.append(datasets)
                assert datasets == {"id": 1, "type": "thread/list_datasets"}
                _write_json(websocket, {
                    "id": 1,
                    "type": "result",
                    "success": True,
                    "result": {"datasets": [{
                        "dataset_id": "provider-dataset",
                        "network_name": "Home Thread",
                        "channel": 15,
                        "pan_id": 4660,
                        "extended_pan_id": "0011223344556677",
                        "preferred": True,
                        "source": "otbr",
                        "preferred_border_agent_id": None,
                        "preferred_extended_address": None,
                    }]},
                })
                discovery = _read_json(websocket)
                self.commands.append(discovery)
                assert discovery == {"id": 2, "type": "thread/discover_routers"}
                _write_json(websocket, {
                    "id": 2, "type": "result", "success": True, "result": None,
                })
                _write_json(websocket, {
                    "id": 2,
                    "type": "event",
                    "event": {
                        "type": "router_discovered",
                        "key": "1122334455667788",
                        "data": {
                            "network_name": "Home Thread",
                            "extended_address": "1122334455667788",
                            "extended_pan_id": "0011223344556677",
                            "border_agent_id": None,
                            "brand": "homeassistant",
                            "model_name": "OTBR",
                            "thread_version": "1.3.0",
                            "vendor_name": "Home Assistant",
                            "unconfigured": False,
                        },
                    },
                })
                _exact(websocket, 2)
        except Exception as error:  # pragma: no cover - asserted by caller
            self.failures.append(error)

    def close(self):
        self.listener.close()
        self.thread.join(timeout=2)


def test_normal_core_uses_verified_service_and_real_thread_websocket(server):
    app, client, _settings, _clock = server
    actor = ready(server)
    upstream = _HomeAssistant()
    try:
        service = client.post(
            "/api/v1/admin/services",
            headers=auth(actor),
            json={
                "kind": "home_assistant",
                "name": "Synthetic Thread HA",
                "baseUrl": upstream.url,
                "credentials": {"token": TOKEN},
            },
        )
        assert service.status_code == 201, service.text
        record = service.json()["service"]
        checked = app.state.core.services.record_verification(
            app.state.core.auth.authenticate(actor["accessToken"]),
            record["id"],
            1,
            state="authenticated",
            version="2026.9.0",
        )
        assert checked["service"]["verification"]["state"] == "authenticated"

        context = app.state.core.context
        root = (
            f"/api/v1/admin/mesh-center/{context.coreId}/{context.homeId}"
            "/thread-diagnostics"
        )
        configuration = client.get(root + "/configuration", headers=auth(actor))
        assert configuration.status_code == 200, configuration.text
        assert configuration.json()["configuration"]["services"] == [{
            "schemaVersion": 1,
            "serviceId": record["id"],
            "serviceRevision": 1,
            "name": "Synthetic Thread HA",
        }]
        saved = client.put(
            root + "/configuration",
            headers=auth(actor),
            json={
                "schemaVersion": 1,
                "expectedRevision": None,
                "serviceId": record["id"],
                "expectedServiceRevision": 1,
            },
        )
        assert saved.status_code == 200, saved.text

        observed = client.get(root, headers=auth(actor))
        assert observed.status_code == 200, observed.text
        body = observed.json()["diagnostics"]
        assert body["datasets"][0]["networkName"] == "Home Thread"
        assert body["routers"][0]["modelName"] == "OTBR"
        assert body["datasets"][0]["datasetId"] != "provider-dataset"
        assert body["routers"][0]["routerId"] != "1122334455667788"
        assert TOKEN not in observed.text
    finally:
        upstream.close()

    assert upstream.failures == []
    assert [item.get("type") for item in upstream.commands] == [
        "auth", "thread/list_datasets", "thread/discover_routers",
    ]
