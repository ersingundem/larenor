"""UID-private, bounded IPC for the F30 Unmanic action worker."""

from collections import deque
import hashlib
import json
import os
import socket
import stat
import struct
import threading
import time
import uuid

from pydantic import ValidationError

from ..peer_credentials import unix_peer_uid

from .models import (
    ArchiveActionWorkerPreview,
    ArchiveActionWorkerReceipt,
    PrivateArchiveActionCommand,
)


PROTOCOL_VERSION = 4
SCHEMA_VERSION = 4
MAX_FRAME_BYTES = 512 * 1024
MAX_REPLAY_KEYS = 512
MAX_DEADLINE_MS = 5_000

_POLICY = {
    "automaticCleanup": False,
    "durableCancellation": True,
    "capability": "media_archive_actions",
    "maxDeadlineMs": MAX_DEADLINE_MS,
    "maxFrameBytes": MAX_FRAME_BYTES,
    "maxReplayKeys": MAX_REPLAY_KEYS,
    "operations": ["preview", "execute", "reconcile"],
    "protocolVersion": PROTOCOL_VERSION,
    "provider": "unmanic",
    "retainedOriginal": True,
    "schemaVersion": SCHEMA_VERSION,
}
MEDIA_ARCHIVE_ACTION_POLICY_DIGEST = hashlib.sha256(json.dumps(
    _POLICY, sort_keys=True, separators=(",", ":"), allow_nan=False,
).encode("utf-8")).hexdigest()


class MediaArchiveActionWorkerError(RuntimeError):
    """A stable, secret-free worker transport failure."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


class UnavailableMediaArchiveActionHandler:
    """Fail-closed placeholder; it never simulates an Unmanic effect."""

    available = False

    def preview(self, _command, *, deadline, gate):
        raise MediaArchiveActionWorkerError("worker_unavailable")

    def execute(self, _command, *, deadline, cancelled):
        raise MediaArchiveActionWorkerError("worker_unavailable")

    def reconcile(self, _command, *, deadline, cancelled):
        raise MediaArchiveActionWorkerError("worker_unavailable")


def _canonical(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), allow_nan=False,
    ).encode("utf-8")


def _read_frame(stream):
    header = bytearray()
    while len(header) < 4:
        part = stream.recv(4 - len(header))
        if not part:
            raise MediaArchiveActionWorkerError("invalid_frame")
        header.extend(part)
    size = struct.unpack("!I", header)[0]
    if not 1 <= size <= MAX_FRAME_BYTES:
        raise MediaArchiveActionWorkerError("invalid_frame")
    parts, remaining = [], size
    while remaining:
        part = stream.recv(remaining)
        if not part:
            raise MediaArchiveActionWorkerError("invalid_frame")
        parts.append(part)
        remaining -= len(part)
    try:
        value = json.loads(b"".join(parts))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise MediaArchiveActionWorkerError("invalid_frame") from None
    if type(value) is not dict:
        raise MediaArchiveActionWorkerError("invalid_frame")
    return value


def _write_frame(stream, value):
    body = _canonical(value)
    if not 1 <= len(body) <= MAX_FRAME_BYTES:
        raise MediaArchiveActionWorkerError("invalid_frame")
    stream.sendall(struct.pack("!I", len(body)) + body)


def _peer_uid(stream):
    try:
        return unix_peer_uid(stream)
    except (OSError, struct.error):
        raise MediaArchiveActionWorkerError("peer_uid_unavailable") from None


def _validate_socket_path(path, owner_uid, *, existing):
    parent = os.path.dirname(os.path.abspath(path))
    parent_stat = os.stat(parent)
    if (parent_stat.st_uid != owner_uid
            or parent_stat.st_mode & 0o022):
        raise MediaArchiveActionWorkerError("unsafe_socket_directory")
    if existing:
        info = os.stat(path, follow_symlinks=False)
        if (info.st_uid != owner_uid or info.st_mode & 0o077
                or not stat.S_ISSOCK(info.st_mode)):
            raise MediaArchiveActionWorkerError("unsafe_socket")


def _status(available):
    return {
        "provider": "unmanic",
        "capability": "media_archive_actions",
        "protocolVersion": PROTOCOL_VERSION,
        "schemaVersion": SCHEMA_VERSION,
        "policyDigest": MEDIA_ARCHIVE_ACTION_POLICY_DIGEST,
        "previewAvailable": bool(available),
        "executeAvailable": bool(available),
        "reconcileAvailable": bool(available),
        "automaticCleanup": False,
    }


def _typed_command(value):
    command = PrivateArchiveActionCommand.model_validate(value)
    if command.target.targetType == "legacy_unresolved":
        raise MediaArchiveActionWorkerError("evidence_changed")
    return command


class MediaArchiveActionWorkerClient:
    def __init__(self, path, *, owner_uid=None, peer_uid=None):
        self.path = path
        self.owner_uid = os.geteuid() if owner_uid is None else owner_uid
        self.peer_uid = self.owner_uid if peer_uid is None else peer_uid

    def _call(self, operation, command=None, *, deadline=None, cancel_requested=False):
        if deadline is None:
            deadline = time.monotonic() + MAX_DEADLINE_MS / 1000
        remaining_ms = min(MAX_DEADLINE_MS, int(
            max(0, deadline - time.monotonic()) * 1000))
        if remaining_ms <= 0:
            raise MediaArchiveActionWorkerError("deadline_exceeded")
        _validate_socket_path(self.path, self.owner_uid, existing=True)
        request_id = uuid.uuid4().hex
        request = {
            "protocolVersion": PROTOCOL_VERSION,
            "schemaVersion": SCHEMA_VERSION,
            "policyDigest": MEDIA_ARCHIVE_ACTION_POLICY_DIGEST,
            "requestId": request_id,
            "operation": operation,
            "deadlineMs": remaining_ms,
        }
        if command is not None:
            request["command"] = command.model_dump(mode="json")
        if operation in {"execute", "reconcile"}:
            request["cancelRequested"] = bool(cancel_requested)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
            stream.settimeout(max(0.001, remaining_ms / 1000))
            stream.connect(self.path)
            if _peer_uid(stream) != self.peer_uid:
                raise MediaArchiveActionWorkerError("peer_uid_mismatch")
            _write_frame(stream, request)
            response = _read_frame(stream)
        if (set(response) not in ({"protocolVersion", "schemaVersion",
                                  "policyDigest", "requestId", "result"},
                                 {"protocolVersion", "schemaVersion",
                                  "policyDigest", "requestId", "errorCode"})
                or response.get("protocolVersion") != PROTOCOL_VERSION
                or response.get("schemaVersion") != SCHEMA_VERSION
                or response.get("policyDigest")
                != MEDIA_ARCHIVE_ACTION_POLICY_DIGEST
                or response.get("requestId") != request_id):
            raise MediaArchiveActionWorkerError("invalid_response")
        if "errorCode" in response:
            raise MediaArchiveActionWorkerError(response["errorCode"])
        return response["result"]

    def status(self):
        result = self._call("status")
        if type(result) is not dict or set(result) != set(_status(False)):
            raise MediaArchiveActionWorkerError("invalid_response")
        return result

    def preview(self, command, *, deadline, gate):
        command = _typed_command(command)
        if not gate():
            raise MediaArchiveActionWorkerError("authority_changed")
        result = ArchiveActionWorkerPreview.model_validate(
            self._call("preview", command, deadline=deadline))
        if not gate():
            raise MediaArchiveActionWorkerError("authority_changed")
        return result

    def execute(self, command, *, deadline, cancelled):
        command = _typed_command(command)
        if cancelled():
            raise MediaArchiveActionWorkerError("cancelled")
        result = ArchiveActionWorkerReceipt.model_validate(
            self._call("execute", command, deadline=deadline, cancel_requested=cancelled()))
        if cancelled() and result.state != "cancelled":
            raise MediaArchiveActionWorkerError("cancel_unknown")
        return result

    def reconcile(self, command, *, deadline, cancelled):
        command = _typed_command(command)
        result = ArchiveActionWorkerReceipt.model_validate(
            self._call("reconcile", command, deadline=deadline, cancel_requested=cancelled()))
        if cancelled() and result.state not in {"cancelled", "succeeded"}:
            raise MediaArchiveActionWorkerError("cancel_unknown")
        return result


class MediaArchiveActionWorkerServer:
    def __init__(self, path, handler=None, *, owner_uid=None, peer_uid=None):
        self.path = path
        self.owner_uid = os.geteuid() if owner_uid is None else owner_uid
        self.peer_uid = self.owner_uid if peer_uid is None else peer_uid
        self.handler = handler or UnavailableMediaArchiveActionHandler()
        self._socket = None
        self._thread = None
        self._socket_identity = None
        self._stopping = threading.Event()
        self._replay_order = deque()
        self._replay_keys = set()
        self._execute_order = deque()
        self._execute_keys = set()
        self._lock = threading.Lock()

    def start(self):
        if self._socket is not None:
            raise MediaArchiveActionWorkerError("already_started")
        _validate_socket_path(self.path, self.owner_uid, existing=False)
        if os.path.lexists(self.path):
            raise MediaArchiveActionWorkerError("socket_path_exists")
        stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stream.bind(self.path)
        info = os.lstat(self.path)
        self._socket_identity = (info.st_dev, info.st_ino)
        os.chmod(self.path, 0o600)
        stream.listen(8)
        stream.settimeout(0.2)
        self._socket = stream
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        return self

    def close(self):
        self._stopping.set()
        if self._socket is not None:
            self._socket.close()
            self._socket = None
        if self._thread is not None:
            self._thread.join(timeout=1)
            self._thread = None
        closer = getattr(self.handler, "close", None)
        if callable(closer):
            closer()
        try:
            info = os.lstat(self.path)
            if self._socket_identity == (info.st_dev, info.st_ino):
                os.unlink(self.path)
        except FileNotFoundError:
            pass
        finally:
            self._socket_identity = None

    def __enter__(self):
        return self.start()

    def __exit__(self, *_args):
        self.close()

    def _serve(self):
        while not self._stopping.is_set():
            try:
                connection, _ = self._socket.accept()
            except (socket.timeout, OSError):
                continue
            with connection:
                connection.settimeout(MAX_DEADLINE_MS / 1000)
                request = None
                try:
                    if _peer_uid(connection) != self.peer_uid:
                        raise MediaArchiveActionWorkerError("peer_uid_mismatch")
                    request = _read_frame(connection)
                    response = self._handle(request)
                except MediaArchiveActionWorkerError as error:
                    request_id = (request.get("requestId")
                                  if type(request) is dict else "0" * 32)
                    response = self._response(
                        request_id, error_code=error.code)
                except (ValidationError, ValueError, TypeError, KeyError):
                    request_id = (request.get("requestId")
                                  if type(request) is dict
                                  and type(request.get("requestId")) is str
                                  and len(request["requestId"]) == 32
                                  else "0" * 32)
                    response = self._response(
                        request_id, error_code="invalid_request")
                except Exception:
                    response = self._response(
                        "0" * 32, error_code="worker_unavailable")
                try:
                    _write_frame(connection, response)
                except (OSError, MediaArchiveActionWorkerError):
                    pass

    @staticmethod
    def _response(request_id, *, result=None, error_code=None):
        value = {
            "protocolVersion": PROTOCOL_VERSION,
            "schemaVersion": SCHEMA_VERSION,
            "policyDigest": MEDIA_ARCHIVE_ACTION_POLICY_DIGEST,
            "requestId": request_id,
        }
        value["errorCode" if error_code else "result"] = (
            error_code if error_code else result)
        return value

    def _handle(self, request):
        required = {"protocolVersion", "schemaVersion", "policyDigest",
                    "requestId", "operation", "deadlineMs"}
        operation = request.get("operation")
        expected = required if operation == "status" else required | {"command"}
        if operation in {"execute", "reconcile"}:
            expected = expected | {"cancelRequested"}
        if (set(request) != expected
                or request.get("protocolVersion") != PROTOCOL_VERSION
                or request.get("schemaVersion") != SCHEMA_VERSION
                or request.get("policyDigest")
                != MEDIA_ARCHIVE_ACTION_POLICY_DIGEST
                or type(request.get("requestId")) is not str
                or len(request["requestId"]) != 32
                or any(char not in "0123456789abcdef"
                       for char in request["requestId"])
                or operation not in {"status", "preview", "execute", "reconcile"}
                or operation in {"execute", "reconcile"}
                and type(request.get("cancelRequested")) is not bool
                or type(request.get("deadlineMs")) is not int
                or not 1 <= request["deadlineMs"] <= MAX_DEADLINE_MS):
            raise MediaArchiveActionWorkerError("invalid_request")
        with self._lock:
            if request["requestId"] in self._replay_keys:
                raise MediaArchiveActionWorkerError("replay_rejected")
            self._replay_keys.add(request["requestId"])
            self._replay_order.append(request["requestId"])
            if len(self._replay_order) > MAX_REPLAY_KEYS:
                self._replay_keys.remove(self._replay_order.popleft())
            if operation == "status":
                return self._response(
                    request["requestId"],
                    result=_status(getattr(self.handler, "available", True)),
                )
            command = _typed_command(request["command"])
            if operation == "execute":
                execute_key = (command.operationId, command.evidenceDigest)
                if execute_key in self._execute_keys:
                    raise MediaArchiveActionWorkerError("replay_rejected")
                self._execute_keys.add(execute_key)
                self._execute_order.append(execute_key)
                if len(self._execute_order) > MAX_REPLAY_KEYS:
                    self._execute_keys.remove(self._execute_order.popleft())
            deadline = time.monotonic() + request["deadlineMs"] / 1000
            stopped = lambda: self._stopping.is_set() or time.monotonic() >= deadline
            if stopped():
                raise MediaArchiveActionWorkerError("deadline_exceeded")
            method = getattr(self.handler, operation, None)
            if not callable(method):
                raise MediaArchiveActionWorkerError("worker_unavailable")
            if operation == "preview":
                result = ArchiveActionWorkerPreview.model_validate(
                    method(command, deadline=deadline, gate=lambda: not stopped()))
            else:
                result = ArchiveActionWorkerReceipt.model_validate(
                    method(command, deadline=deadline, cancelled=lambda: (
                        self._stopping.is_set() or request["cancelRequested"])))
            if stopped():
                raise MediaArchiveActionWorkerError("deadline_exceeded")
            return self._response(
                request["requestId"], result=result.model_dump(mode="json"))
