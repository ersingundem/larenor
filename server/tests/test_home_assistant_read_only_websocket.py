"""Real loopback wire test for fixed Home Assistant registry reads."""

import base64
import hashlib
import json
import socket
import struct
import threading
from types import MappingProxyType

from larenor_server.home_assistant.read_only_websocket import (
    HomeAssistantReadOnlyWebSocket,
    HomeAssistantWebSocketError,
    _json,
)
from larenor_server.services.service import ServiceConnection


TOKEN = "synthetic-private-token"


def _exact(stream, count):
    result = bytearray()
    while len(result) < count:
        part = stream.recv(count - len(result))
        if not part:
            raise EOFError
        result.extend(part)
    return bytes(result)


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


def test_fixed_registry_methods_send_no_caller_selected_command_or_payload():
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]
    commands = []
    failure = []
    guarded_addresses = []

    def server():
        try:
            stream, _ = listener.accept()
            with stream:
                request = b""
                while b"\r\n\r\n" not in request:
                    request += stream.recv(4096)
                headers = {}
                for line in request.split(b"\r\n")[1:]:
                    if b":" in line:
                        key, value = line.split(b":", 1)
                        headers[key.decode().lower()] = value.decode().strip()
                accept = base64.b64encode(hashlib.sha1(
                    (headers["sec-websocket-key"]
                     + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
                ).digest()).decode()
                stream.sendall((
                    "HTTP/1.1 101 Switching Protocols\r\n"
                    "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                    f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
                ).encode())
                _write_json(stream, {"type": "auth_required"})
                commands.append(_read_json(stream))
                _write_json(stream, {"type": "auth_ok"})
                for request_id, command_type, result in (
                    (1, "config/entity_registry/list", [{
                        "entity_id": "switch.driveway_recordings",
                        "platform": "frigate",
                    }]),
                    (2, "config/device_registry/list", [{
                        "id": "a" * 32,
                        "manufacturer": "Fronius",
                    }]),
                ):
                    command = _read_json(stream)
                    commands.append(command)
                    assert command == {"id": request_id, "type": command_type}
                    _write_json(stream, {
                        "id": request_id,
                        "type": "result",
                        "success": True,
                        "result": result,
                    })
                _exact(stream, 2)
        except Exception as error:
            failure.append(error)

    thread = threading.Thread(target=server, daemon=True)
    thread.start()
    connection = ServiceConnection(
        id="b" * 32,
        name="Fixture",
        kind="home_assistant",
        base_url=f"http://127.0.0.1:{port}",
        revision=3,
        credentials=MappingProxyType({"token": TOKEN}),
    )
    try:
        with HomeAssistantReadOnlyWebSocket(
            connection,
            address_guard=guarded_addresses.append,
        ).session(timeout=2) as session:
            entities = session.list_entity_registry()
            devices = session.list_device_registry()
    finally:
        listener.close()
        thread.join(timeout=2)

    assert failure == []
    assert commands == [
        {"type": "auth", "access_token": TOKEN},
        {"id": 1, "type": "config/entity_registry/list"},
        {"id": 2, "type": "config/device_registry/list"},
    ]
    assert entities[0]["platform"] == "frigate"
    assert devices[0]["manufacturer"] == "Fronius"
    assert guarded_addresses == ["127.0.0.1", "127.0.0.1"]


def test_invalid_timeout_fails_before_resolution_or_network_io():
    calls = []
    connection = ServiceConnection(
        id="b" * 32,
        name="Fixture",
        kind="home_assistant",
        base_url="http://ha.invalid",
        revision=3,
        credentials=MappingProxyType({"token": TOKEN}),
    )
    client = HomeAssistantReadOnlyWebSocket(
        connection,
        resolver=lambda *_: calls.append("resolved"),
    )

    for timeout in (True, 0, 61, float("nan"), float("inf")):
        try:
            with client.session(timeout=timeout):
                raise AssertionError("session unexpectedly opened")
        except HomeAssistantWebSocketError as error:
            assert error.code == "unavailable"
    assert calls == []


def test_deep_malformed_json_fails_closed_without_recursion_escape():
    try:
        _json(b"[" * 4096 + b"]" * 4096)
    except HomeAssistantWebSocketError as error:
        assert error.code == "invalid_response"
    else:
        raise AssertionError("malformed JSON unexpectedly accepted")
