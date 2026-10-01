"""Exact-peer Unix IPC for the host-owned systemd AI runtime."""

from __future__ import annotations

import json
import errno
import os
from pathlib import Path
import socket
import stat
import struct
import time
import uuid

from ..peer_credentials import unix_peer_uid
from .runtime import AiDispatch, AiRuntimeError, AiRuntimeObservation


PROTOCOL_VERSION = 1
MAX_FRAME_BYTES = 16 * 1024
MAX_DEADLINE_MS = 12_000
ACCEPT_POLL_SECONDS = 0.25
_KINDS = frozenset({"assistant", "vision", "embedding", "automation"})


def _pairs(items):
    value = {}
    for key, item in items:
        if key in value:
            raise ValueError()
        value[key] = item
    return value


def _remaining(deadline):
    value = deadline - time.monotonic()
    if value <= 0:
        raise AiRuntimeError()
    return value


def _read_exact(stream, size, deadline):
    value = bytearray()
    while len(value) < size:
        stream.settimeout(_remaining(deadline))
        part = stream.recv(size - len(value))
        if not part:
            raise AiRuntimeError()
        value.extend(part)
    return bytes(value)


def _read_frame(stream, deadline):
    try:
        size = struct.unpack("!I", _read_exact(stream, 4, deadline))[0]
        if not 1 <= size <= MAX_FRAME_BYTES:
            raise ValueError()
        return json.loads(
            _read_exact(stream, size, deadline).decode("ascii"),
            object_pairs_hook=_pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
    except AiRuntimeError:
        raise
    except (OSError, ValueError, TypeError, UnicodeError, RecursionError, struct.error):
        raise AiRuntimeError("invalid_runtime_response") from None


def _write_frame(stream, value, deadline):
    try:
        raw = json.dumps(
            value, sort_keys=True, separators=(",", ":"),
            ensure_ascii=True, allow_nan=False,
        ).encode("ascii")
        if not 1 <= len(raw) <= MAX_FRAME_BYTES:
            raise ValueError()
        stream.settimeout(_remaining(deadline))
        stream.sendall(struct.pack("!I", len(raw)) + raw)
    except AiRuntimeError:
        raise
    except (OSError, ValueError, TypeError, UnicodeError, RecursionError):
        raise AiRuntimeError() from None


def _validate_socket_path(path):
    value = Path(path)
    if not value.is_absolute() or ".." in value.parts or len(os.fsencode(value)) > 100:
        raise AiRuntimeError("invalid_runtime_configuration")
    return value


def _check_socket(path, owner_uid, socket_gid):
    try:
        value = os.stat(path, follow_symlinks=False)
        if (
            not stat.S_ISSOCK(value.st_mode)
            or value.st_uid != owner_uid
            or value.st_gid != socket_gid
            or stat.S_IMODE(value.st_mode) != 0o660
        ):
            raise ValueError()
    except (OSError, ValueError):
        raise AiRuntimeError() from None


def _dispatch_to_wire(value):
    if type(value) is not AiDispatch:
        raise AiRuntimeError("invalid_runtime_response")
    return {
        "jobId": value.job_id,
        "dispatchId": value.dispatch_id,
        "requestKey": value.request_key,
        "kind": value.kind,
        "memoryMb": value.memory_mb,
        "cpuPercent": value.cpu_percent,
    }


def _dispatch_from_wire(value):
    if type(value) is not dict or set(value) != {
        "jobId", "dispatchId", "requestKey", "kind", "memoryMb", "cpuPercent"
    }:
        raise AiRuntimeError("invalid_runtime_response")
    try:
        return AiDispatch(
            value["jobId"], value["dispatchId"], value["requestKey"],
            value["kind"], value["memoryMb"], value["cpuPercent"],
        )
    except AiRuntimeError:
        raise
    except Exception:
        raise AiRuntimeError("invalid_runtime_response") from None


def _observation_to_wire(value):
    if type(value) is not AiRuntimeObservation:
        raise AiRuntimeError("invalid_runtime_response")
    return {
        "phase": value.phase,
        "resultCode": value.result_code,
        "exitCode": value.exit_code,
        "memoryPeakMb": value.memory_peak_mb,
        "cpuMillis": value.cpu_millis,
        "outputSha256": value.output_sha256,
        "outputBytes": value.output_bytes,
    }


def _observation_from_wire(value):
    if type(value) is not dict or set(value) != {
        "phase", "resultCode", "exitCode", "memoryPeakMb", "cpuMillis",
        "outputSha256", "outputBytes",
    }:
        raise AiRuntimeError("invalid_runtime_response")
    try:
        return AiRuntimeObservation(
            value["phase"], value["resultCode"], value["exitCode"],
            value["memoryPeakMb"], value["cpuMillis"],
            value["outputSha256"], value["outputBytes"],
        )
    except AiRuntimeError:
        raise
    except Exception:
        raise AiRuntimeError("invalid_runtime_response") from None


class AiWorkerClient:
    enforcement = "systemdCgroupV2"

    def __init__(self, path, *, owner_uid, peer_uid, socket_gid=None):
        self.path = _validate_socket_path(path)
        self.owner_uid = owner_uid
        self.peer_uid = peer_uid
        self.socket_gid = os.getegid() if socket_gid is None else socket_gid
        if any(type(value) is not int or not 0 <= value < 2**31 for value in (
            owner_uid, peer_uid, self.socket_gid
        )):
            raise AiRuntimeError("invalid_runtime_configuration")

    def _request(self, operation, *, dispatch=None, kind=None):
        _check_socket(self.path, self.owner_uid, self.socket_gid)
        deadline = time.monotonic() + MAX_DEADLINE_MS / 1000
        request_id = uuid.uuid4().hex
        request = {
            "protocolVersion": PROTOCOL_VERSION,
            "requestId": request_id,
            "operation": operation,
            "deadlineMs": MAX_DEADLINE_MS,
        }
        if dispatch is not None:
            request["dispatch"] = _dispatch_to_wire(dispatch)
        if kind is not None:
            if kind not in _KINDS:
                raise AiRuntimeError("invalid_runtime_response")
            request["kind"] = kind
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
                stream.settimeout(_remaining(deadline))
                stream.connect(str(self.path))
                if unix_peer_uid(stream) != self.peer_uid:
                    raise AiRuntimeError()
                _write_frame(stream, request, deadline)
                response = _read_frame(stream, deadline)
        except AiRuntimeError:
            raise
        except (OSError, TimeoutError, struct.error):
            raise AiRuntimeError() from None
        if (
            type(response) is not dict
            or response.get("protocolVersion") != PROTOCOL_VERSION
            or response.get("requestId") != request_id
            or set(response) not in (
                {"protocolVersion", "requestId", "result"},
                {"protocolVersion", "requestId", "error"},
            )
        ):
            raise AiRuntimeError("invalid_runtime_response")
        if "error" in response:
            raise AiRuntimeError(response["error"])
        return response["result"]

    def available(self):
        try:
            return self._request("available") is True
        except AiRuntimeError:
            return False

    def supports(self, kind):
        try:
            return self._request("supports", kind=kind) is True
        except AiRuntimeError:
            return False

    def provider(self, kind):
        try:
            value = self._request("provider", kind=kind)
            if value is not None and (
                type(value) is not str or not 1 <= len(value) <= 64
            ):
                raise AiRuntimeError("invalid_runtime_response")
            return value
        except AiRuntimeError:
            return None

    def start(self, dispatch):
        return _observation_from_wire(self._request("start", dispatch=dispatch))

    def observe(self, dispatch):
        return _observation_from_wire(self._request("observe", dispatch=dispatch))

    def cancel(self, dispatch):
        return _observation_from_wire(self._request("cancel", dispatch=dispatch))

    def release(self, dispatch):
        if self._request("release", dispatch=dispatch) is not True:
            raise AiRuntimeError("invalid_runtime_response")


class AiWorkerServer:
    def __init__(self, path, runtime, *, owner_uid, peer_uid, socket_gid=None):
        self.path = _validate_socket_path(path)
        self.runtime = runtime
        self.owner_uid = owner_uid
        self.peer_uid = peer_uid
        self.socket_gid = os.getegid() if socket_gid is None else socket_gid
        self._socket = None
        self._identity = None
        if os.geteuid() != owner_uid or any(
            type(value) is not int or not 0 <= value < 2**31
            for value in (owner_uid, peer_uid, self.socket_gid)
        ):
            raise AiRuntimeError("invalid_runtime_configuration")

    def bind(self):
        try:
            parent = os.stat(self.path.parent, follow_symlinks=False)
            if not stat.S_ISDIR(parent.st_mode) or parent.st_mode & 0o007:
                raise ValueError()
            if os.path.lexists(self.path):
                current = os.stat(self.path, follow_symlinks=False)
                identity = (current.st_dev, current.st_ino)
                if (
                    not stat.S_ISSOCK(current.st_mode)
                    or current.st_uid != self.owner_uid
                    or current.st_gid != self.socket_gid
                    or stat.S_IMODE(current.st_mode) != 0o660
                ):
                    raise ValueError()
                probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                try:
                    probe.settimeout(0.2)
                    probe.connect(str(self.path))
                except OSError as error:
                    if error.errno not in {errno.ECONNREFUSED, errno.ENOENT}:
                        raise
                else:
                    raise ValueError()
                finally:
                    probe.close()
                checked = os.stat(self.path, follow_symlinks=False)
                if identity != (checked.st_dev, checked.st_ino):
                    raise ValueError()
                self.path.unlink()
            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(str(self.path))
            os.chown(self.path, self.owner_uid, self.socket_gid)
            os.chmod(self.path, 0o660)
            server.listen(16)
            server.settimeout(ACCEPT_POLL_SECONDS)
            current = os.stat(self.path, follow_symlinks=False)
            self._identity = (current.st_dev, current.st_ino)
            self._socket = server
            return self
        except Exception:
            try:
                server.close()
            except Exception:
                pass
            raise AiRuntimeError() from None

    def _handle(self, stream):
        request_id = "0" * 32
        deadline = time.monotonic() + MAX_DEADLINE_MS / 1000
        try:
            if unix_peer_uid(stream) != self.peer_uid:
                raise AiRuntimeError()
            request = _read_frame(stream, deadline)
            if (
                type(request) is not dict
                or request.get("protocolVersion") != PROTOCOL_VERSION
                or type(request.get("requestId")) is not str
                or len(request["requestId"]) != 32
                or any(char not in "0123456789abcdef" for char in request["requestId"])
                or type(request.get("deadlineMs")) is not int
                or not 1 <= request["deadlineMs"] <= MAX_DEADLINE_MS
            ):
                raise AiRuntimeError("invalid_runtime_response")
            request_id = request["requestId"]
            operation = request.get("operation")
            expected = {
                "available": set(), "supports": {"kind"}, "provider": {"kind"},
                "start": {"dispatch"}, "observe": {"dispatch"},
                "cancel": {"dispatch"}, "release": {"dispatch"},
            }.get(operation)
            common = {"protocolVersion", "requestId", "operation", "deadlineMs"}
            if expected is None or set(request) != common | expected:
                raise AiRuntimeError("invalid_runtime_response")
            deadline = time.monotonic() + request["deadlineMs"] / 1000
            if operation == "available":
                result = self.runtime.available()
            elif operation in {"supports", "provider"}:
                if request["kind"] not in _KINDS:
                    raise AiRuntimeError("invalid_runtime_response")
                result = getattr(self.runtime, operation)(request["kind"])
            else:
                dispatch = _dispatch_from_wire(request["dispatch"])
                result = getattr(self.runtime, operation)(dispatch)
                result = True if operation == "release" else _observation_to_wire(result)
            response = {"protocolVersion": 1, "requestId": request_id, "result": result}
        except AiRuntimeError as error:
            response = {"protocolVersion": 1, "requestId": request_id, "error": error.code}
        except Exception:
            response = {"protocolVersion": 1, "requestId": request_id, "error": "worker_unavailable"}
        try:
            _write_frame(stream, response, deadline)
        except AiRuntimeError:
            pass

    def serve_forever(self):
        if self._socket is None:
            self.bind()
        server = self._socket
        if server is None:
            return
        while self._socket is server:
            try:
                stream, _address = server.accept()
            except TimeoutError:
                continue
            except OSError:
                if self._socket is None or self._socket is not server:
                    return
                raise
            if self._socket is not server:
                stream.close()
                return
            with stream:
                self._handle(stream)

    def close(self):
        server, self._socket = self._socket, None
        if server is not None:
            server.close()
        try:
            current = os.stat(self.path, follow_symlinks=False)
            if self._identity == (current.st_dev, current.st_ino):
                self.path.unlink()
        except FileNotFoundError:
            pass
        self._identity = None
