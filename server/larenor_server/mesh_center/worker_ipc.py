"""UID-private IPC for the read-only Zigbee2MQTT observation worker."""

from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import stat
import struct
import time
import uuid

from ..peer_credentials import unix_peer_uid
from .zigbee2mqtt_provider import (
    MAX_DEVICE_STATE_BYTES,
    MAX_DEVICES,
    MAX_RETAINED_BYTES,
    Zigbee2MqttObservation,
)

PROTOCOL_VERSION = 1
MAX_FRAME_BYTES = 12 * 1024 * 1024
MAX_DEADLINE_MS = 15_000
_ID = __import__("re").compile(r"[0-9a-f]{32}\Z")


class MeshWorkerError(RuntimeError):
    """Stable, secret-free failure from the private worker boundary."""

    def __init__(self, code="worker_unavailable"):
        self.code = code if code in {
            "worker_unavailable",
            "invalid_request",
            "invalid_response",
            "deadline_exceeded",
        } else "worker_unavailable"
        super().__init__(self.code)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_json_key")
        result[key] = value
    return result


def _remaining(deadline):
    value = deadline - time.monotonic()
    if value <= 0:
        raise MeshWorkerError("deadline_exceeded")
    return value


def _read_exact(stream, count, deadline):
    result = bytearray()
    while len(result) < count:
        stream.settimeout(_remaining(deadline))
        try:
            part = stream.recv(count - len(result))
        except (OSError, TimeoutError):
            raise MeshWorkerError("worker_unavailable") from None
        if not part:
            raise MeshWorkerError("worker_unavailable")
        result.extend(part)
    return bytes(result)


def _read_frame(stream, deadline):
    try:
        size = struct.unpack("!I", _read_exact(stream, 4, deadline))[0]
        if not 1 <= size <= MAX_FRAME_BYTES:
            raise MeshWorkerError("invalid_response")
        return json.loads(
            _read_exact(stream, size, deadline),
            object_pairs_hook=_pairs,
            parse_constant=lambda _: (_ for _ in ()).throw(ValueError()),
        )
    except MeshWorkerError:
        raise
    except (ValueError, TypeError, UnicodeError, RecursionError, struct.error):
        raise MeshWorkerError("invalid_response") from None


def _write_frame(stream, value, deadline):
    try:
        payload = json.dumps(
            value, separators=(",", ":"), ensure_ascii=True, allow_nan=False
        ).encode("ascii")
        if not 1 <= len(payload) <= MAX_FRAME_BYTES:
            raise MeshWorkerError("invalid_response")
        stream.settimeout(_remaining(deadline))
        stream.sendall(struct.pack("!I", len(payload)) + payload)
    except MeshWorkerError:
        raise
    except (OSError, ValueError, TypeError, UnicodeError, RecursionError):
        raise MeshWorkerError("worker_unavailable") from None


def _safe_socket(path, owner_uid, *, existing):
    path = Path(path)
    if (
        not path.is_absolute()
        or ".." in path.parts
        or len(os.fsencode(path)) > 100
    ):
        raise MeshWorkerError()
    try:
        parent = path.parent.stat()
        if parent.st_uid != owner_uid or parent.st_mode & 0o022:
            raise MeshWorkerError()
        if existing:
            current = path.stat(follow_symlinks=False)
            if (
                current.st_uid != owner_uid
                or current.st_mode & 0o077
                or not stat.S_ISSOCK(current.st_mode)
            ):
                raise MeshWorkerError()
    except OSError:
        raise MeshWorkerError() from None


def _peer_uid(stream):
    try:
        return unix_peer_uid(stream)
    except (OSError, struct.error):
        raise MeshWorkerError() from None


def _text(value, maximum):
    if not isinstance(value, str):
        raise MeshWorkerError("invalid_response")
    raw = value.encode("utf-8")
    if not 1 <= len(raw) <= maximum:
        raise MeshWorkerError("invalid_response")
    return raw


def _observation_to_wire(value):
    if not isinstance(value, Zigbee2MqttObservation):
        raise MeshWorkerError("invalid_response")
    try:
        states = {key: raw.decode("utf-8") for key, raw in value.deviceStates.items()}
        availability = {
            key: raw.decode("utf-8") for key, raw in value.availability.items()
        }
        result = {
            "revision": value.revision,
            "capturedAtMs": value.capturedAtMs,
            "bridgeState": value.bridgeState.decode("utf-8"),
            "bridgeInfo": value.bridgeInfo.decode("utf-8"),
            "devices": value.devices.decode("utf-8"),
            "deviceStates": states,
            "availability": availability,
        }
        _observation_from_wire(result)
        return result
    except UnicodeError:
        raise MeshWorkerError("invalid_response") from None


def _observation_from_wire(value):
    if not isinstance(value, dict) or set(value) != {
        "revision",
        "capturedAtMs",
        "bridgeState",
        "bridgeInfo",
        "devices",
        "deviceStates",
        "availability",
    }:
        raise MeshWorkerError("invalid_response")
    if (
        type(value["revision"]) is not int
        or not 1 <= value["revision"] <= 2**63 - 1
        or type(value["capturedAtMs"]) is not int
        or not 0 <= value["capturedAtMs"] <= 2**63 - 1
        or not isinstance(value["deviceStates"], dict)
        or not isinstance(value["availability"], dict)
        or len(value["deviceStates"]) > MAX_DEVICES
        or len(value["availability"]) > MAX_DEVICES
    ):
        raise MeshWorkerError("invalid_response")
    bridge_state = _text(value["bridgeState"], 1_024)
    bridge_info = _text(value["bridgeInfo"], MAX_RETAINED_BYTES)
    devices = _text(value["devices"], MAX_RETAINED_BYTES)
    states = {}
    availability = {}
    for target, raw_values, maximum in (
        (states, value["deviceStates"], MAX_DEVICE_STATE_BYTES),
        (availability, value["availability"], 1_024),
    ):
        for key, raw in raw_values.items():
            if (
                not isinstance(key, str)
                or not 1 <= len(key) <= 256
                or "\0" in key
                or key in target
            ):
                raise MeshWorkerError("invalid_response")
            target[key] = _text(raw, maximum)
    return Zigbee2MqttObservation(
        revision=value["revision"],
        capturedAtMs=value["capturedAtMs"],
        bridgeState=bridge_state,
        bridgeInfo=bridge_info,
        devices=devices,
        deviceStates=states,
        availability=availability,
    )


class Zigbee2MqttWorkerClient:
    def __init__(self, path, *, owner_uid=None, peer_uid=None):
        self.path = Path(path)
        self.owner_uid = os.geteuid() if owner_uid is None else owner_uid
        self.peer_uid = self.owner_uid if peer_uid is None else peer_uid

    def observe(self, *, timeout=8.0):
        if (
            not isinstance(timeout, (int, float))
            or isinstance(timeout, bool)
            or not 0 < timeout <= MAX_DEADLINE_MS / 1_000
        ):
            raise MeshWorkerError("invalid_request")
        _safe_socket(self.path, self.owner_uid, existing=True)
        deadline = time.monotonic() + timeout
        request_id = uuid.uuid4().hex
        request = {
            "protocolVersion": PROTOCOL_VERSION,
            "requestId": request_id,
            "operation": "observe",
            "deadlineMs": max(1, min(MAX_DEADLINE_MS, int(timeout * 1_000))),
        }
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
                stream.settimeout(_remaining(deadline))
                stream.connect(str(self.path))
                if _peer_uid(stream) != self.peer_uid:
                    raise MeshWorkerError()
                _write_frame(stream, request, deadline)
                response = _read_frame(stream, deadline)
        except MeshWorkerError:
            raise
        except OSError:
            raise MeshWorkerError() from None
        if (
            not isinstance(response, dict)
            or response.get("protocolVersion") != PROTOCOL_VERSION
            or response.get("requestId") != request_id
            or set(response) not in (
                {"protocolVersion", "requestId", "observation"},
                {"protocolVersion", "requestId", "error"},
            )
        ):
            raise MeshWorkerError("invalid_response")
        if "error" in response:
            raise MeshWorkerError(response["error"])
        return _observation_from_wire(response["observation"])


class Zigbee2MqttWorkerServer:
    def __init__(self, path, observer, *, owner_uid=None, peer_uid=None):
        self.path = Path(path)
        self.observer = observer
        self.owner_uid = os.geteuid() if owner_uid is None else owner_uid
        self.peer_uid = self.owner_uid if peer_uid is None else peer_uid
        self._socket = None
        self._socket_identity = None

    def bind(self):
        _safe_socket(self.path, self.owner_uid, existing=False)
        if os.path.lexists(self.path):
            raise MeshWorkerError()
        try:
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(self.path))
            info = os.lstat(self.path)
            self._socket_identity = (info.st_dev, info.st_ino)
            os.chmod(self.path, 0o600)
            server.listen(8)
            self._socket = server
        except OSError:
            raise MeshWorkerError() from None
        return self

    def _handle(self, stream):
        request_id = "0" * 32
        deadline = time.monotonic() + MAX_DEADLINE_MS / 1_000
        try:
            if _peer_uid(stream) != self.peer_uid:
                raise MeshWorkerError()
            request = _read_frame(stream, deadline)
            if (
                not isinstance(request, dict)
                or set(request) != {
                    "protocolVersion", "requestId", "operation", "deadlineMs"
                }
                or request.get("protocolVersion") != PROTOCOL_VERSION
                or not isinstance(request.get("requestId"), str)
                or _ID.fullmatch(request["requestId"]) is None
                or request.get("operation") != "observe"
                or type(request.get("deadlineMs")) is not int
                or not 1 <= request["deadlineMs"] <= MAX_DEADLINE_MS
            ):
                raise MeshWorkerError("invalid_request")
            request_id = request["requestId"]
            deadline = time.monotonic() + request["deadlineMs"] / 1_000
            observation = self.observer.observe(timeout=_remaining(deadline))
            response = {
                "protocolVersion": PROTOCOL_VERSION,
                "requestId": request_id,
                "observation": _observation_to_wire(observation),
            }
        except MeshWorkerError as error:
            response = {
                "protocolVersion": PROTOCOL_VERSION,
                "requestId": request_id,
                "error": error.code,
            }
        except Exception as error:
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            response = {
                "protocolVersion": PROTOCOL_VERSION,
                "requestId": request_id,
                "error": "worker_unavailable",
            }
        try:
            _write_frame(stream, response, deadline)
        except MeshWorkerError:
            pass

    def serve_forever(self):
        if self._socket is None:
            self.bind()
        while self._socket is not None:
            try:
                stream, _ = self._socket.accept()
            except OSError:
                if self._socket is None:
                    return
                raise
            with stream:
                self._handle(stream)

    def close(self):
        server, self._socket = self._socket, None
        if server is not None:
            server.close()
        try:
            info = os.lstat(self.path)
            if self._socket_identity == (info.st_dev, info.st_ino):
                self.path.unlink()
        except FileNotFoundError:
            pass
        finally:
            self._socket_identity = None
