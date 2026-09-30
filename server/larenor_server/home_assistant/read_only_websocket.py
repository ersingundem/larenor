"""Credential-private, fixed-command Home Assistant WebSocket transport."""

from __future__ import annotations

from contextlib import contextmanager
import base64
import hashlib
import json
import math
import secrets
import socket
import ssl
import struct
import time

from ..services.service import ServiceConnection
from ..errors import ApiError
from ..services.transport import (
    ProbeTransportError,
    _Deadline,
    _Reader,
    _base,
    _remaining,
    _resolve,
    _resolve_system,
)
from ..vault import validate_json_bounds

_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_FRAME = 1024 * 1024
MAX_REGISTRY_ENTRIES = 65_536
MAX_THREAD_EVENTS = 128


class HomeAssistantWebSocketError(RuntimeError):
    def __init__(self, code="unavailable"):
        self.code = code if code in {
            "unavailable", "unauthorized", "unsupported", "invalid_response",
            "timeout", "authority_changed",
        } else "unavailable"
        super().__init__(self.code)


def _json(payload):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError
            result[key] = value
        return result

    try:
        value = json.loads(
            payload.decode("utf-8"),
            object_pairs_hook=pairs,
            parse_constant=lambda _: (_ for _ in ()).throw(ValueError()),
        )
        validate_json_bounds(value)
        if not isinstance(value, dict):
            raise ValueError
        return value
    except (
        ValueError,
        TypeError,
        UnicodeError,
        RecursionError,
        json.JSONDecodeError,
        ApiError,
    ):
        raise HomeAssistantWebSocketError("invalid_response") from None


def _exact(stream, count, deadline):
    result = bytearray()
    while len(result) < count:
        stream.settimeout(_remaining(deadline))
        part = stream.recv(count - len(result))
        if not part:
            raise HomeAssistantWebSocketError("unavailable")
        result.extend(part)
    return bytes(result)


def _read_frame(stream, deadline):
    header = _exact(stream, 2, deadline)
    if header[0] & 0x70 or not header[0] & 0x80 or header[1] & 0x80:
        raise HomeAssistantWebSocketError("invalid_response")
    opcode = header[0] & 0x0F
    length = header[1] & 0x7F
    if length == 126:
        length = struct.unpack("!H", _exact(stream, 2, deadline))[0]
    elif length == 127:
        length = struct.unpack("!Q", _exact(stream, 8, deadline))[0]
    if length > MAX_FRAME or opcode not in {1, 8, 9, 10}:
        raise HomeAssistantWebSocketError("invalid_response")
    return opcode, _exact(stream, length, deadline)


def _send_frame(stream, opcode, payload, deadline):
    if not isinstance(payload, bytes) or len(payload) > MAX_FRAME:
        raise HomeAssistantWebSocketError("invalid_response")
    mask = secrets.token_bytes(4)
    length = len(payload)
    header = bytes([0x80 | opcode])
    if length < 126:
        header += bytes([0x80 | length])
    elif length <= 65535:
        header += b"\xfe" + struct.pack("!H", length)
    else:
        header += b"\xff" + struct.pack("!Q", length)
    masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    stream.settimeout(_remaining(deadline))
    stream.sendall(header + mask + masked)


def _message(stream, deadline):
    while True:
        opcode, payload = _read_frame(stream, deadline)
        if opcode == 9:
            _send_frame(stream, 10, payload, deadline)
            continue
        if opcode == 8:
            raise HomeAssistantWebSocketError("unavailable")
        if opcode == 1:
            return _json(payload)


def _command(stream, value, deadline):
    payload = json.dumps(
        value, separators=(",", ":"), ensure_ascii=True, allow_nan=False
    ).encode("ascii")
    _send_frame(stream, 1, payload, deadline)


class _ReadOnlySession:
    def __init__(self, stream, deadline):
        self._stream = stream
        self._deadline = deadline
        self._next_id = 1

    def _request(self, command_type):
        request_id = self._next_id
        self._next_id += 1
        _command(
            self._stream,
            {"id": request_id, "type": command_type},
            self._deadline,
        )
        result = _message(self._stream, self._deadline)
        if (
            result.get("id") != request_id
            or result.get("type") != "result"
            or result.get("success") is not True
        ):
            raise HomeAssistantWebSocketError("unsupported")
        return request_id, result.get("result")

    def list_entity_registry(self):
        """Run only ``config/entity_registry/list``; no caller payload exists."""
        _, result = self._request("config/entity_registry/list")
        if (
            not isinstance(result, list)
            or len(result) > MAX_REGISTRY_ENTRIES
            or any(not isinstance(item, dict) for item in result)
        ):
            raise HomeAssistantWebSocketError("invalid_response")
        return tuple(result)

    def list_device_registry(self):
        """Run only ``config/device_registry/list``; no caller payload exists."""
        _, result = self._request("config/device_registry/list")
        if (
            not isinstance(result, list)
            or len(result) > MAX_REGISTRY_ENTRIES
            or any(not isinstance(item, dict) for item in result)
        ):
            raise HomeAssistantWebSocketError("invalid_response")
        return tuple(result)

    def list_thread_datasets(self):
        """Run only ``thread/list_datasets``."""
        _, result = self._request("thread/list_datasets")
        if not isinstance(result, dict):
            raise HomeAssistantWebSocketError("invalid_response")
        return result

    def discover_thread_routers(self, window):
        """Open one bounded ``thread/discover_routers`` subscription."""
        request_id, result = self._request("thread/discover_routers")
        if result is not None:
            raise HomeAssistantWebSocketError("invalid_response")
        events = []
        discovery_deadline = min(self._deadline, time.monotonic() + window)
        while time.monotonic() < discovery_deadline:
            try:
                event = _message(self._stream, discovery_deadline)
            except (TimeoutError, socket.timeout, ProbeTransportError):
                break
            if (
                event.get("id") != request_id
                or event.get("type") != "event"
                or not isinstance(event.get("event"), dict)
                or len(events) >= MAX_THREAD_EVENTS
            ):
                raise HomeAssistantWebSocketError("invalid_response")
            events.append(event["event"])
        return tuple(events)


class HomeAssistantReadOnlyWebSocket:
    """Open an authenticated session exposing only reviewed read commands."""

    def __init__(
        self,
        connection: ServiceConnection,
        *,
        resolver=None,
        connector=None,
        address_guard=None,
    ):
        if (
            not isinstance(connection, ServiceConnection)
            or connection.kind != "home_assistant"
            or set(connection.credentials) != {"token"}
        ):
            raise HomeAssistantWebSocketError("unsupported")
        self.connection = connection
        self._resolver = resolver or _resolve_system
        self._connector = connector
        self._address_guard = address_guard
        self._scheme, self._host, self._port, self._authority, self._prefix = _base(
            connection.base_url
        )

    @contextmanager
    def session(
        self,
        *,
        timeout=8.0,
        before_io=lambda: None,
        after_io=lambda: None,
    ):
        if (
            type(timeout) not in (int, float)
            or isinstance(timeout, bool)
            or not math.isfinite(timeout)
            or not 0 < timeout <= 60
            or not callable(before_io)
            or not callable(after_io)
        ):
            raise HomeAssistantWebSocketError("unavailable")
        deadline = time.monotonic() + timeout
        scope = _Deadline(deadline)
        try:
            family, address = _resolve(
                self._resolver,
                self._host,
                self._port,
                deadline,
                self._address_guard,
            )
            if self._connector is None:
                stream = socket.socket(family, socket.SOCK_STREAM)
                scope.attach(stream)
                stream.settimeout(_remaining(deadline))
                stream.connect(address)
            else:
                stream = self._connector(family, address, _remaining(deadline))
                scope.attach(stream)
            if self._scheme == "https":
                stream = ssl.create_default_context().wrap_socket(
                    stream,
                    server_hostname=self._host,
                    do_handshake_on_connect=False,
                )
                scope.attach(stream)
                stream.settimeout(_remaining(deadline))
                stream.do_handshake()
            if stream.getpeername() != address:
                raise HomeAssistantWebSocketError("unavailable")
            before_io()
            key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
            route = self._prefix + "/api/websocket"
            request = (
                f"GET {route} HTTP/1.1\r\nHost: {self._authority}\r\n"
                "Connection: Upgrade\r\nUpgrade: websocket\r\n"
                f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            ).encode("ascii")
            stream.settimeout(_remaining(deadline))
            stream.sendall(request)
            reader = _Reader(stream, deadline)
            if reader.line(8192) != b"HTTP/1.1 101 Switching Protocols\r\n":
                raise HomeAssistantWebSocketError("unavailable")
            headers = {}
            while True:
                line = reader.line(8192)
                if line == b"\r\n":
                    break
                if b":" not in line or len(headers) >= 32:
                    raise HomeAssistantWebSocketError("invalid_response")
                name, value = line[:-2].split(b":", 1)
                name = name.decode("ascii").lower()
                if name in headers:
                    raise HomeAssistantWebSocketError("invalid_response")
                headers[name] = value.decode("ascii").strip()
            expected = base64.b64encode(
                hashlib.sha1(key.encode("ascii") + _GUID).digest()
            ).decode("ascii")
            if (
                headers.get("upgrade", "").lower() != "websocket"
                or "upgrade" not in headers.get("connection", "").lower().split(",")
                or not secrets.compare_digest(
                    headers.get("sec-websocket-accept", ""), expected
                )
            ):
                raise HomeAssistantWebSocketError("invalid_response")
            required = _message(stream, deadline)
            if required.get("type") != "auth_required":
                raise HomeAssistantWebSocketError("invalid_response")
            if self._address_guard is not None:
                self._address_guard(stream.getpeername()[0])
            _command(
                stream,
                {"type": "auth", "access_token": self.connection.credentials["token"]},
                deadline,
            )
            authenticated = _message(stream, deadline)
            if authenticated.get("type") == "auth_invalid":
                raise HomeAssistantWebSocketError("unauthorized")
            if authenticated.get("type") != "auth_ok":
                raise HomeAssistantWebSocketError("invalid_response")
            yield _ReadOnlySession(stream, deadline)
            after_io()
            _send_frame(stream, 8, b"", deadline)
        except HomeAssistantWebSocketError:
            raise
        except ProbeTransportError as error:
            code = "timeout" if error.code == "request_timeout" else "unavailable"
            raise HomeAssistantWebSocketError(code) from None
        except (OSError, TimeoutError, ssl.SSLError, ValueError, TypeError, UnicodeError):
            raise HomeAssistantWebSocketError("unavailable") from None
        finally:
            scope.finish()
