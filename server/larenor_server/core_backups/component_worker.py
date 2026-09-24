"""Private bounded IPC client for host-owned component backup snapshots."""

import hashlib
import json
import math
import re
import socket
import stat
import struct
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

from .service import (
    MAX_COMPONENT_BYTES,
    MAX_COMPONENT_VOLUME_BYTES,
    ComponentVolumeSnapshot,
)

PROTOCOL = 1
MAX_HEADER_BYTES = 64 * 1024
MAX_SNAPSHOTS = 128
_SERVICE_ID = re.compile(r"[a-z][a-z0-9_]{0,63}\Z")
_VOLUME_ID = re.compile(r"[a-z][a-z0-9-]{0,127}\Z")
_SAFE_VALUE = re.compile(r"[\x21-\x7e]{1,128}\Z")
_DIGEST = re.compile(r"[0-9a-f]{64}\Z")
_CAPTURE_GENERATION = re.compile(r"[0-9a-f]{32}\Z")


class ComponentSnapshotWorkerError(RuntimeError):
    """Static public failures; paths and worker payloads never escape."""

    def __init__(self, code="worker_unavailable"):
        self.code = (
            code
            if code in {"worker_unavailable", "invalid_worker_result"}
            else "worker_unavailable"
        )
        super().__init__(self.code)


def _remaining(deadline):
    remaining = deadline - time.monotonic()
    if not math.isfinite(deadline) or remaining <= 0:
        raise ComponentSnapshotWorkerError()
    return remaining


def _receive(connection, count, deadline):
    value = bytearray()
    while len(value) < count:
        connection.settimeout(_remaining(deadline))
        try:
            part = connection.recv(min(count - len(value), 64 * 1024))
        except TimeoutError:
            raise ComponentSnapshotWorkerError() from None
        if not part:
            raise ComponentSnapshotWorkerError("invalid_worker_result")
        value.extend(part)
    return bytes(value)


def _pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise ValueError()
        result[key] = value
    return result


def _read_frame(connection, deadline):
    try:
        count = struct.unpack("!I", _receive(connection, 4, deadline))[0]
        if not 1 <= count <= MAX_HEADER_BYTES:
            raise ComponentSnapshotWorkerError("invalid_worker_result")
        value = json.loads(
            _receive(connection, count, deadline).decode("utf-8"),
            object_pairs_hook=_pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
        if type(value) is not dict:
            raise ComponentSnapshotWorkerError("invalid_worker_result")
        return value
    except ComponentSnapshotWorkerError:
        raise
    except (OSError, UnicodeError, ValueError, TypeError, struct.error, RecursionError):
        raise ComponentSnapshotWorkerError("invalid_worker_result") from None


def _write_frame(connection, value, deadline):
    try:
        raw = json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("ascii")
        if not 1 <= len(raw) <= MAX_HEADER_BYTES:
            raise ComponentSnapshotWorkerError()
        connection.settimeout(_remaining(deadline))
        connection.sendall(struct.pack("!I", len(raw)) + raw)
    except ComponentSnapshotWorkerError:
        raise
    except (OSError, UnicodeError, ValueError, TypeError, RecursionError):
        raise ComponentSnapshotWorkerError() from None


def _peer_uid(connection):
    if not hasattr(socket, "SO_PEERCRED"):
        raise ComponentSnapshotWorkerError()
    try:
        return struct.unpack(
            "3i",
            connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12),
        )[1]
    except (OSError, struct.error):
        raise ComponentSnapshotWorkerError() from None


def _socket_identity(path, owner_uid):
    try:
        info = path.lstat()
    except OSError:
        raise ComponentSnapshotWorkerError() from None
    if (
        not stat.S_ISSOCK(info.st_mode)
        or info.st_uid != owner_uid
        or stat.S_IMODE(info.st_mode) not in {0o600, 0o660}
        or info.st_nlink != 1
    ):
        raise ComponentSnapshotWorkerError()
    return info.st_dev, info.st_ino


def _safe_text(value, pattern):
    return type(value) is str and pattern.fullmatch(value) is not None


class ComponentSnapshotWorkerClient:
    """Single-flight, peer-authenticated quiescence and snapshot client."""

    def __init__(self, path, *, owner_uid=0, peer_uid=None):
        candidate = Path(path)
        if (
            not candidate.is_absolute()
            or ".." in candidate.parts
            or any(ord(char) < 32 or ord(char) == 127 for char in str(candidate))
            or type(owner_uid) is not int
            or not 0 <= owner_uid < 2**31
            or (peer_uid is not None and not callable(peer_uid))
        ):
            raise ComponentSnapshotWorkerError()
        self.path = candidate
        self.owner_uid = owner_uid
        self.peer_uid = _peer_uid if peer_uid is None else peer_uid
        self._lock = threading.Lock()

    def _connect(self, deadline):
        identity = _socket_identity(self.path, self.owner_uid)
        try:
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.settimeout(_remaining(deadline))
            connection.connect(str(self.path))
            actual_uid = self.peer_uid(connection)
            if (
                _socket_identity(self.path, self.owner_uid) != identity
                or type(actual_uid) is not int
                or actual_uid != self.owner_uid
            ):
                raise ComponentSnapshotWorkerError()
            return connection
        except ComponentSnapshotWorkerError:
            if "connection" in locals():
                connection.close()
            raise
        except (OSError, TypeError, ValueError):
            if "connection" in locals():
                connection.close()
            raise ComponentSnapshotWorkerError() from None

    @staticmethod
    def _descriptors(response, request_id):
        if (
            set(response) != {"protocol", "requestId", "status", "snapshots"}
            or type(response.get("protocol")) is not int
            or response["protocol"] != PROTOCOL
            or response.get("requestId") != request_id
            or response.get("status") != "ready"
            or type(response.get("snapshots")) is not list
            or len(response["snapshots"]) > MAX_SNAPSHOTS
        ):
            raise ComponentSnapshotWorkerError("invalid_worker_result")
        descriptors = []
        total = 0
        seen = set()
        keys = {
            "serviceId",
            "serviceVersion",
            "configSchemaVersion",
            "dataSchemaVersion",
            "captureGeneration",
            "volumeId",
            "byteLength",
            "sha256",
        }
        for descriptor in response["snapshots"]:
            if type(descriptor) is not dict or set(descriptor) != keys:
                raise ComponentSnapshotWorkerError("invalid_worker_result")
            identity = (descriptor.get("serviceId"), descriptor.get("volumeId"))
            size = descriptor.get("byteLength")
            if (
                not _safe_text(descriptor.get("serviceId"), _SERVICE_ID)
                or not _safe_text(descriptor.get("serviceVersion"), _SAFE_VALUE)
                or type(descriptor.get("configSchemaVersion")) is not int
                or not 1 <= descriptor["configSchemaVersion"] <= 2**31 - 1
                or not _safe_text(descriptor.get("dataSchemaVersion"), _SAFE_VALUE)
                or not _safe_text(
                    descriptor.get("captureGeneration"), _CAPTURE_GENERATION
                )
                or not _safe_text(descriptor.get("volumeId"), _VOLUME_ID)
                or type(size) is not int
                or not 1 <= size <= MAX_COMPONENT_VOLUME_BYTES
                or not _safe_text(descriptor.get("sha256"), _DIGEST)
                or identity in seen
            ):
                raise ComponentSnapshotWorkerError("invalid_worker_result")
            total += size
            if total > MAX_COMPONENT_BYTES:
                raise ComponentSnapshotWorkerError("invalid_worker_result")
            seen.add(identity)
            descriptors.append(descriptor)
        return descriptors

    @contextmanager
    def quiesce(self, deadline):
        now = time.monotonic()
        if (
            type(deadline) not in (int, float)
            or type(deadline) is bool
            or not now < deadline <= now + 5
        ):
            raise ComponentSnapshotWorkerError()
        if not self._lock.acquire(timeout=_remaining(deadline)):
            raise ComponentSnapshotWorkerError()
        connection = None
        request_id = uuid.uuid4().hex
        try:
            connection = self._connect(deadline)
            _write_frame(
                connection,
                {
                    "protocol": PROTOCOL,
                    "requestId": request_id,
                    "operation": "quiesce",
                    "timeoutMilliseconds": max(
                        1, min(5000, int(_remaining(deadline) * 1000))
                    ),
                },
                deadline,
            )
            response = _read_frame(connection, deadline)
            operation_failed = False
            try:
                descriptors = self._descriptors(response, request_id)
                snapshots = []
                for descriptor in descriptors:
                    payload = _receive(
                        connection, descriptor["byteLength"], deadline
                    )
                    if hashlib.sha256(payload).hexdigest() != descriptor["sha256"]:
                        raise ComponentSnapshotWorkerError("invalid_worker_result")
                    snapshots.append(
                        ComponentVolumeSnapshot(
                            serviceId=descriptor["serviceId"],
                            serviceVersion=descriptor["serviceVersion"],
                            configSchemaVersion=descriptor["configSchemaVersion"],
                            dataSchemaVersion=descriptor["dataSchemaVersion"],
                            captureGeneration=descriptor["captureGeneration"],
                            volumeId=descriptor["volumeId"],
                            payload=payload,
                        )
                    )
                yield tuple(snapshots)
            except BaseException:
                operation_failed = True
                raise
            finally:
                try:
                    _write_frame(
                        connection,
                        {
                            "protocol": PROTOCOL,
                            "requestId": request_id,
                            "operation": "release",
                        },
                        deadline,
                    )
                    released = _read_frame(connection, deadline)
                    if released != {
                        "protocol": PROTOCOL,
                        "requestId": request_id,
                        "status": "released",
                    }:
                        raise ComponentSnapshotWorkerError("invalid_worker_result")
                except ComponentSnapshotWorkerError:
                    if not operation_failed:
                        raise
        except ComponentSnapshotWorkerError:
            raise
        except (OSError, TypeError, ValueError):
            raise ComponentSnapshotWorkerError() from None
        finally:
            if connection is not None:
                connection.close()
            self._lock.release()
