"""Loopback wire acceptance for read-only Home Assistant Thread diagnostics."""

import base64
import hashlib
import json
from types import MappingProxyType
import socket
import struct
import threading

import pytest

from larenor_server.home_assistant.read_only_websocket import (
    HomeAssistantReadOnlyWebSocket,
)
from larenor_server.mesh_center.thread_diagnostics import (
    HomeAssistantThreadDiagnosticsTransport,
    ThreadDiagnosticsError,
)
from larenor_server.services.service import ServiceConnection


TOKEN = "synthetic-home-assistant-token"
SERVICE_ID = "a" * 32
ROUTER_ID = "A1B2C3D4E5F60708"


def _exact(stream, count):
    result = bytearray()
    while len(result) < count:
        part = stream.recv(count - len(result))
        if not part:
            raise EOFError
        result.extend(part)
    return bytes(result)


def _client_json(stream):
    first, second = _exact(stream, 2)
    assert first == 0x81 and second & 0x80
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", _exact(stream, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", _exact(stream, 8))[0]
    mask = _exact(stream, 4)
    payload = _exact(stream, length)
    decoded = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    return json.loads(decoded)


def _server_json(stream, value):
    payload = json.dumps(value, separators=(",", ":")).encode()
    if len(payload) < 126:
        header = bytes((0x81, len(payload)))
    elif len(payload) <= 65535:
        header = b"\x81\x7e" + struct.pack("!H", len(payload))
    else:
        header = b"\x81\x7f" + struct.pack("!Q", len(payload))
    stream.sendall(header + payload)


class _HomeAssistantFixture:
    def __init__(self, *, token=TOKEN, registry=False):
        self.token = token
        self.registry = registry
        self.commands = []
        self.ready = threading.Event()
        self.done = threading.Event()
        self.error = None
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()
        assert self.ready.wait(1)

    def _serve(self):
        self.ready.set()
        try:
            self.listener.settimeout(2)
            stream, _ = self.listener.accept()
            with stream:
                stream.settimeout(2)
                request = b""
                while b"\r\n\r\n" not in request:
                    part = stream.recv(4096)
                    if not part:
                        return
                    request += part
                headers = {}
                for line in request.split(b"\r\n")[1:]:
                    if b":" in line:
                        name, value = line.split(b":", 1)
                        headers[name.decode().lower()] = value.decode().strip()
                key = headers["sec-websocket-key"]
                accept = base64.b64encode(
                    hashlib.sha1(
                        (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
                    ).digest()
                ).decode()
                stream.sendall(
                    (
                        "HTTP/1.1 101 Switching Protocols\r\n"
                        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                        f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
                    ).encode()
                )
                _server_json(stream, {"type": "auth_required", "ha_version": "2026.9"})
                auth = _client_json(stream)
                self.commands.append(auth)
                if auth != {"type": "auth", "access_token": self.token}:
                    _server_json(stream, {"type": "auth_invalid", "message": "discarded"})
                    return
                _server_json(stream, {"type": "auth_ok", "ha_version": "2026.9"})
                listed = _client_json(stream)
                self.commands.append(listed)
                if self.registry:
                    _server_json(stream, {
                        "id": 1,
                        "type": "result",
                        "success": True,
                        "result": [{
                            "entity_id": "switch.camera_recordings",
                            "platform": "frigate",
                            "config_entry_id": "b" * 32,
                            "device_id": "c" * 32,
                            "unique_id": "driveway_recordings",
                        }],
                    })
                    try:
                        _exact(stream, 2)
                    except (EOFError, OSError, TimeoutError):
                        pass
                    return
                _server_json(stream, {
                    "id": 1,
                    "type": "result",
                    "success": True,
                    "result": {"datasets": [{
                        "channel": 15,
                        "created": 1.0,
                        "dataset_id": "dataset-home",
                        "extended_pan_id": "0011223344556677",
                        "network_name": "Home Thread",
                        "pan_id": 4660,
                        "preferred": True,
                        "preferred_border_agent_id": "1" * 32,
                        "preferred_extended_address": "1122334455667788",
                        "source": "otbr",
                    }]},
                })
                discovered = _client_json(stream)
                self.commands.append(discovered)
                _server_json(stream, {
                    "id": 2, "type": "result", "success": True, "result": None,
                })
                _server_json(stream, {
                    "id": 2,
                    "type": "event",
                    "event": {
                        "type": "router_discovered",
                        "key": ROUTER_ID,
                        "data": {
                            "instance_name": "router._meshcop._udp.local.",
                            "addresses": ["192.0.2.10"],
                            "border_agent_id": "2" * 32,
                            "brand": "homeassistant",
                            "extended_address": ROUTER_ID,
                            "extended_pan_id": "0011223344556677",
                            "model_name": "OTBR",
                            "network_name": "Home Thread",
                            "server": "router.local.",
                            "thread_version": "1.3.0",
                            "unconfigured": False,
                            "vendor_name": "Home Assistant",
                        },
                    },
                })
                try:
                    _exact(stream, 2)
                except (EOFError, OSError, TimeoutError):
                    pass
        except Exception as error:  # test fixture reports failures to the test thread
            self.error = error
        finally:
            self.done.set()

    def close(self):
        if not self.done.wait(2):
            self.listener.close()
        self.thread.join(timeout=2)
        self.listener.close()
        if self.error is not None:
            raise self.error


def _connection(fixture, *, token=TOKEN):
    return ServiceConnection(
        id=SERVICE_ID,
        name="Home Assistant fixture",
        kind="home_assistant",
        base_url=f"http://127.0.0.1:{fixture.port}",
        revision=7,
        credentials=MappingProxyType({"token": token}),
    )


def test_read_only_home_assistant_thread_snapshot_uses_fixed_commands():
    fixture = _HomeAssistantFixture()
    guards = []
    try:
        snapshot = HomeAssistantThreadDiagnosticsTransport(
            _connection(fixture), clock=lambda: 1234.5
        ).observe(
            timeout=2,
            discovery_window=0.05,
            before_io=lambda: guards.append("before"),
            after_io=lambda: guards.append("after"),
        )
    finally:
        fixture.close()

    assert guards == ["before", "before", "after", "before", "after", "after"]
    assert fixture.commands == [
        {"type": "auth", "access_token": TOKEN},
        {"id": 1, "type": "thread/list_datasets"},
        {"id": 2, "type": "thread/discover_routers"},
    ]
    assert snapshot.serviceId == SERVICE_ID
    assert snapshot.serviceRevision == 7
    assert snapshot.capturedAtMs == 1_234_500
    assert snapshot.readOnly is True
    assert snapshot.datasets[0].datasetId == "dataset-home"
    assert snapshot.datasets[0].preferred is True
    assert snapshot.routers[0].routerId == ROUTER_ID.lower()
    assert snapshot.routers[0].networkName == "Home Thread"
    assert TOKEN not in repr(snapshot)


def test_wrong_home_assistant_token_is_rejected_without_provider_message():
    fixture = _HomeAssistantFixture(token="different-token")
    try:
        with pytest.raises(ThreadDiagnosticsError) as error:
            HomeAssistantThreadDiagnosticsTransport(_connection(fixture)).observe(
                timeout=2, discovery_window=0
            )
    finally:
        fixture.close()

    assert error.value.code == "unauthorized"
    assert TOKEN not in str(error.value)


def test_reusable_transport_exposes_only_fixed_entity_registry_list():
    fixture = _HomeAssistantFixture(registry=True)
    try:
        with HomeAssistantReadOnlyWebSocket(_connection(fixture)).session(
            timeout=2
        ) as session:
            entities = session.list_entity_registry()
    finally:
        fixture.close()

    assert fixture.commands == [
        {"type": "auth", "access_token": TOKEN},
        {"id": 1, "type": "config/entity_registry/list"},
    ]
    assert entities[0]["unique_id"] == "driveway_recordings"


def test_authority_guard_stops_before_http_or_credentials_are_sent():
    fixture = _HomeAssistantFixture()

    def changed():
        raise ThreadDiagnosticsError("authority_changed")

    try:
        with pytest.raises(ThreadDiagnosticsError) as error:
            HomeAssistantThreadDiagnosticsTransport(_connection(fixture)).observe(
                timeout=2, discovery_window=0, before_io=changed
            )
    finally:
        fixture.close()

    assert error.value.code == "authority_changed"
    assert fixture.commands == []
