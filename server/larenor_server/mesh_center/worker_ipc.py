"""UID-private IPC for the read-only Zigbee2MQTT observation worker."""

from __future__ import annotations

import errno
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
from .managed_ota_transport import (
    MAX_CHECK_SECONDS,
    MAX_UPDATE_SECONDS,
    ManagedOtaInstallEvidence,
    ManagedOtaOfferEvidence,
    ManagedOtaTransportError,
)

PROTOCOL_VERSION = 1
MAX_FRAME_BYTES = 12 * 1024 * 1024
MAX_DEADLINE_MS = 15_000
MAX_OTA_CHECK_DEADLINE_MS = int(MAX_CHECK_SECONDS * 1_000)
MAX_OTA_UPDATE_DEADLINE_MS = int(MAX_UPDATE_SECONDS * 1_000)
_ID = __import__("re").compile(r"[0-9a-f]{32}\Z")


class MeshWorkerError(RuntimeError):
    """Stable, secret-free failure from the private worker boundary."""

    def __init__(self, code="worker_unavailable"):
        self.code = code if code in {
            "worker_unavailable",
            "invalid_request",
            "invalid_response",
            "deadline_exceeded",
            "revision_conflict",
            "device_not_found",
            "device_unavailable",
            "battery_too_low",
            "no_update",
            "provider_rejected",
            "readback_mismatch",
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


def _safe_socket(path, owner_uid, socket_gid, *, existing, trusted_uids=()):
    path = Path(path)
    if (
        not path.is_absolute()
        or ".." in path.parts
        or len(os.fsencode(path)) > 100
    ):
        raise MeshWorkerError()
    try:
        allowed_uids = {0, owner_uid, os.geteuid(), *trusted_uids}
        for ancestor in path.parents[1:]:
            current = os.stat(ancestor, follow_symlinks=False)
            if (
                not stat.S_ISDIR(current.st_mode)
                or current.st_uid not in allowed_uids
                or current.st_mode & 0o022
            ):
                raise MeshWorkerError()
        parent = os.stat(path.parent, follow_symlinks=False)
        if (
            parent.st_uid != owner_uid
            or parent.st_gid != socket_gid
            or parent.st_mode & 0o002
            or not stat.S_ISDIR(parent.st_mode)
        ):
            raise MeshWorkerError()
        if existing:
            current = path.stat(follow_symlinks=False)
            if (
                current.st_uid != owner_uid
                or current.st_gid != socket_gid
                or stat.S_IMODE(current.st_mode) != 0o660
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


def _offer_to_wire(value):
    if not isinstance(value, ManagedOtaOfferEvidence):
        raise MeshWorkerError("invalid_response")
    result = {
        "deviceId": value.deviceId,
        "providerRevision": value.providerRevision,
        "installedFileVersion": value.installedFileVersion,
        "latestFileVersion": value.latestFileVersion,
        "sourceDigest": value.sourceDigest,
        "checkedAtMs": value.checkedAtMs,
        "releaseNotesAvailable": value.releaseNotesAvailable,
    }
    _offer_from_wire(result)
    return result


def _offer_from_wire(value):
    if not isinstance(value, dict) or set(value) != {
        "deviceId", "providerRevision", "installedFileVersion",
        "latestFileVersion", "sourceDigest", "checkedAtMs",
        "releaseNotesAvailable",
    }:
        raise MeshWorkerError("invalid_response")
    if (
        not isinstance(value["deviceId"], str)
        or _ID.fullmatch(value["deviceId"]) is None
        or type(value["providerRevision"]) is not int
        or not 1 <= value["providerRevision"] <= 2**63 - 1
        or type(value["installedFileVersion"]) is not int
        or not 0 <= value["installedFileVersion"] <= 2**32 - 1
        or type(value["latestFileVersion"]) is not int
        or not value["installedFileVersion"] < value["latestFileVersion"] <= 2**32 - 1
        or not isinstance(value["sourceDigest"], str)
        or __import__("re").fullmatch(r"[0-9a-f]{64}", value["sourceDigest"]) is None
        or type(value["checkedAtMs"]) is not int
        or not 0 <= value["checkedAtMs"] <= 2**63 - 1
        or type(value["releaseNotesAvailable"]) is not bool
    ):
        raise MeshWorkerError("invalid_response")
    return ManagedOtaOfferEvidence(**value)


def _install_to_wire(value):
    if not isinstance(value, ManagedOtaInstallEvidence):
        raise MeshWorkerError("invalid_response")
    result = {
        "deviceId": value.deviceId,
        "previousProviderRevision": value.previousProviderRevision,
        "providerRevision": value.providerRevision,
        "fromFileVersion": value.fromFileVersion,
        "toFileVersion": value.toFileVersion,
        "installedFileVersion": value.installedFileVersion,
        "progressPercent": value.progressPercent,
        "completedAtMs": value.completedAtMs,
    }
    _install_from_wire(result)
    return result


def _install_from_wire(value):
    if not isinstance(value, dict) or set(value) != {
        "deviceId", "previousProviderRevision", "providerRevision",
        "fromFileVersion", "toFileVersion", "installedFileVersion",
        "progressPercent", "completedAtMs",
    }:
        raise MeshWorkerError("invalid_response")
    integers = (
        "previousProviderRevision", "providerRevision", "fromFileVersion",
        "toFileVersion", "installedFileVersion", "progressPercent", "completedAtMs",
    )
    if (
        not isinstance(value["deviceId"], str)
        or _ID.fullmatch(value["deviceId"]) is None
        or any(type(value[key]) is not int for key in integers)
        or not 1 <= value["previousProviderRevision"] < value["providerRevision"] <= 2**63 - 1
        or not 0 <= value["fromFileVersion"] < value["toFileVersion"] <= 2**32 - 1
        or value["installedFileVersion"] != value["toFileVersion"]
        or not 0 <= value["progressPercent"] <= 100
        or not 0 <= value["completedAtMs"] <= 2**63 - 1
    ):
        raise MeshWorkerError("invalid_response")
    return ManagedOtaInstallEvidence(**value)


class Zigbee2MqttWorkerClient:
    def __init__(self, path, *, owner_uid=None, peer_uid=None, socket_gid=None):
        self.path = Path(path)
        self.owner_uid = os.geteuid() if owner_uid is None else owner_uid
        self.peer_uid = self.owner_uid if peer_uid is None else peer_uid
        self.socket_gid = os.getegid() if socket_gid is None else socket_gid
        if any(
            type(value) is not int or not 0 <= value < 2**31
            for value in (self.owner_uid, self.peer_uid, self.socket_gid)
        ):
            raise MeshWorkerError("invalid_request")

    def observe(self, *, timeout=8.0):
        if (
            not isinstance(timeout, (int, float))
            or isinstance(timeout, bool)
            or not 0 < timeout <= MAX_DEADLINE_MS / 1_000
        ):
            raise MeshWorkerError("invalid_request")
        _safe_socket(
            self.path,
            self.owner_uid,
            self.socket_gid,
            existing=True,
            trusted_uids=(self.peer_uid,),
        )
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

    def _managed_request(self, operation, values, timeout, maximum, result_key, parser):
        if (
            not isinstance(timeout, (int, float))
            or isinstance(timeout, bool)
            or not 0 < timeout <= maximum / 1_000
        ):
            raise MeshWorkerError("invalid_request")
        _safe_socket(
            self.path,
            self.owner_uid,
            self.socket_gid,
            existing=True,
            trusted_uids=(self.peer_uid,),
        )
        deadline = time.monotonic() + timeout
        request_id = uuid.uuid4().hex
        request = {
            "protocolVersion": PROTOCOL_VERSION,
            "requestId": request_id,
            "operation": operation,
            "deadlineMs": max(1, min(maximum, int(timeout * 1_000))),
            **values,
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
                {"protocolVersion", "requestId", result_key},
                {"protocolVersion", "requestId", "error"},
            )
        ):
            raise MeshWorkerError("invalid_response")
        if "error" in response:
            raise MeshWorkerError(response["error"])
        return parser(response[result_key])

    def check_managed_ota(self, device_id, expected_provider_revision, *, timeout=30.0):
        if (
            not isinstance(device_id, str)
            or _ID.fullmatch(device_id) is None
            or type(expected_provider_revision) is not int
            or not 1 <= expected_provider_revision <= 2**63 - 1
        ):
            raise MeshWorkerError("invalid_request")
        return self._managed_request(
            "managed_ota_check",
            {
                "deviceId": device_id,
                "expectedProviderRevision": expected_provider_revision,
            },
            timeout,
            MAX_OTA_CHECK_DEADLINE_MS,
            "offer",
            _offer_from_wire,
        )

    def install_managed_ota(
        self,
        device_id,
        expected_provider_revision,
        installed_file_version,
        latest_file_version,
        *,
        timeout=MAX_UPDATE_SECONDS,
    ):
        if (
            not isinstance(device_id, str)
            or _ID.fullmatch(device_id) is None
            or type(expected_provider_revision) is not int
            or not 1 <= expected_provider_revision <= 2**63 - 1
            or type(installed_file_version) is not int
            or type(latest_file_version) is not int
            or not 0 <= installed_file_version < latest_file_version <= 2**32 - 1
        ):
            raise MeshWorkerError("invalid_request")
        return self._managed_request(
            "managed_ota_install",
            {
                "deviceId": device_id,
                "expectedProviderRevision": expected_provider_revision,
                "installedFileVersion": installed_file_version,
                "latestFileVersion": latest_file_version,
            },
            timeout,
            MAX_OTA_UPDATE_DEADLINE_MS,
            "readback",
            _install_from_wire,
        )


class Zigbee2MqttWorkerServer:
    def __init__(
        self,
        path,
        observer,
        *,
        managed_ota=None,
        owner_uid=None,
        peer_uid=None,
        socket_gid=None,
    ):
        self.path = Path(path)
        self.observer = observer
        self.managed_ota = managed_ota
        self.owner_uid = os.geteuid() if owner_uid is None else owner_uid
        self.peer_uid = self.owner_uid if peer_uid is None else peer_uid
        self.socket_gid = os.getegid() if socket_gid is None else socket_gid
        self._socket = None
        self._socket_identity = None
        if os.geteuid() != self.owner_uid or any(
            type(value) is not int or not 0 <= value < 2**31
            for value in (self.owner_uid, self.peer_uid, self.socket_gid)
        ):
            raise MeshWorkerError("invalid_request")

    def bind(self):
        _safe_socket(
            self.path,
            self.owner_uid,
            self.socket_gid,
            existing=False,
            trusted_uids=(self.peer_uid,),
        )
        try:
            if os.path.lexists(self.path):
                current = os.stat(self.path, follow_symlinks=False)
                identity = (current.st_dev, current.st_ino)
                if (
                    not stat.S_ISSOCK(current.st_mode)
                    or current.st_uid != self.owner_uid
                    or current.st_gid != self.socket_gid
                    or stat.S_IMODE(current.st_mode) != 0o660
                ):
                    raise MeshWorkerError()
                probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                try:
                    probe.settimeout(0.2)
                    probe.connect(str(self.path))
                except OSError as error:
                    if error.errno not in {errno.ECONNREFUSED, errno.ENOENT}:
                        raise MeshWorkerError() from None
                else:
                    raise MeshWorkerError()
                finally:
                    probe.close()
                checked = os.stat(self.path, follow_symlinks=False)
                if identity != (checked.st_dev, checked.st_ino):
                    raise MeshWorkerError()
                self.path.unlink()
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(self.path))
            info = os.lstat(self.path)
            self._socket_identity = (info.st_dev, info.st_ino)
            os.chown(self.path, self.owner_uid, self.socket_gid)
            os.chmod(self.path, 0o660)
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
                or request.get("protocolVersion") != PROTOCOL_VERSION
                or not isinstance(request.get("requestId"), str)
                or _ID.fullmatch(request["requestId"]) is None
                or type(request.get("deadlineMs")) is not int
            ):
                raise MeshWorkerError("invalid_request")
            request_id = request["requestId"]
            operation = request.get("operation")
            expected = {
                "observe": {
                    "protocolVersion", "requestId", "operation", "deadlineMs"
                },
                "managed_ota_check": {
                    "protocolVersion", "requestId", "operation", "deadlineMs",
                    "deviceId", "expectedProviderRevision",
                },
                "managed_ota_install": {
                    "protocolVersion", "requestId", "operation", "deadlineMs",
                    "deviceId", "expectedProviderRevision", "installedFileVersion",
                    "latestFileVersion",
                },
            }.get(operation)
            maximum = {
                "observe": MAX_DEADLINE_MS,
                "managed_ota_check": MAX_OTA_CHECK_DEADLINE_MS,
                "managed_ota_install": MAX_OTA_UPDATE_DEADLINE_MS,
            }.get(operation)
            if (
                expected is None
                or set(request) != expected
                or not 1 <= request["deadlineMs"] <= maximum
            ):
                raise MeshWorkerError("invalid_request")
            deadline = time.monotonic() + request["deadlineMs"] / 1_000
            if operation == "observe":
                observation = self.observer.observe(timeout=_remaining(deadline))
                response = {
                    "protocolVersion": PROTOCOL_VERSION,
                    "requestId": request_id,
                    "observation": _observation_to_wire(observation),
                }
            elif operation == "managed_ota_check":
                if (
                    self.managed_ota is None
                    or not isinstance(request["deviceId"], str)
                    or _ID.fullmatch(request["deviceId"]) is None
                    or type(request["expectedProviderRevision"]) is not int
                    or not 1 <= request["expectedProviderRevision"] <= 2**63 - 1
                ):
                    raise MeshWorkerError("invalid_request")
                offer = self.managed_ota.check(
                    request["deviceId"],
                    request["expectedProviderRevision"],
                    timeout=_remaining(deadline),
                )
                response = {
                    "protocolVersion": PROTOCOL_VERSION,
                    "requestId": request_id,
                    "offer": _offer_to_wire(offer),
                }
            else:
                if (
                    self.managed_ota is None
                    or not isinstance(request["deviceId"], str)
                    or _ID.fullmatch(request["deviceId"]) is None
                    or type(request["expectedProviderRevision"]) is not int
                    or not 1 <= request["expectedProviderRevision"] <= 2**63 - 1
                    or type(request["installedFileVersion"]) is not int
                    or type(request["latestFileVersion"]) is not int
                    or not 0 <= request["installedFileVersion"] < request["latestFileVersion"] <= 2**32 - 1
                ):
                    raise MeshWorkerError("invalid_request")
                readback = self.managed_ota.install(
                    request["deviceId"],
                    request["expectedProviderRevision"],
                    request["installedFileVersion"],
                    request["latestFileVersion"],
                    timeout=_remaining(deadline),
                )
                response = {
                    "protocolVersion": PROTOCOL_VERSION,
                    "requestId": request_id,
                    "readback": _install_to_wire(readback),
                }
        except (MeshWorkerError, ManagedOtaTransportError) as error:
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
