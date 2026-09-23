"""Host-owned, peer-authenticated component snapshot worker server."""

import hashlib
import os
import socket
import stat
import threading
import time
from pathlib import Path

from ..files import checked_path
from .component_worker import (
    PROTOCOL,
    ComponentSnapshotWorkerError,
    _peer_uid,
    _read_frame,
    _remaining,
    _write_frame,
)
from .service import ComponentVolumeSnapshot, CoreBackupContract


def _invalid_configuration():
    raise ValueError("invalid_worker_configuration")


class ComponentSnapshotWorkerServer:
    """Serves one bounded snapshot at a time over a private Unix socket."""

    def __init__(
        self,
        path,
        provider,
        *,
        owner_uid=0,
        client_uid=None,
        peer_uid=None,
        monotonic=time.monotonic,
    ):
        if client_uid is None:
            client_uid = owner_uid
        candidate = Path(path)
        try:
            checked_path(candidate)
            parent = candidate.parent.lstat()
        except Exception:
            _invalid_configuration()
        if (
            not candidate.is_absolute()
            or ".." in candidate.parts
            or len(os.fsencode(candidate)) > 100
            or any(ord(char) < 32 or ord(char) == 127 for char in str(candidate))
            or candidate.exists()
            or type(owner_uid) is not int
            or not 0 <= owner_uid < 2**31
            or type(client_uid) is not int
            or not 0 <= client_uid < 2**31
            or peer_uid is not None
            and not callable(peer_uid)
            or not hasattr(provider, "quiesce")
            or not callable(provider.quiesce)
            or not stat.S_ISDIR(parent.st_mode)
            or parent.st_uid != owner_uid
            or stat.S_IMODE(parent.st_mode) & 0o022
        ):
            _invalid_configuration()
        self.path = candidate
        self.provider = provider
        self.owner_uid = owner_uid
        self.client_uid = client_uid
        self.peer_uid = _peer_uid if peer_uid is None else peer_uid
        self.monotonic = monotonic
        self.completed = 0
        self._ready = threading.Event()
        self._stop = threading.Event()
        self._listener = None
        self._identity = None
        self._lock = threading.Lock()

    def wait_ready(self, timeout):
        return self._ready.wait(timeout)

    @staticmethod
    def _request(value, now):
        if (
            set(value) != {
                "protocol",
                "requestId",
                "operation",
                "timeoutMilliseconds",
            }
            or value.get("protocol") != PROTOCOL
            or type(value.get("requestId")) is not str
            or len(value["requestId"]) != 32
            or any(char not in "0123456789abcdef" for char in value["requestId"])
            or value.get("operation") != "quiesce"
            or type(value.get("timeoutMilliseconds")) is not int
            or not 1 <= value["timeoutMilliseconds"] <= 5000
        ):
            raise ComponentSnapshotWorkerError("invalid_worker_result")
        return value["requestId"], now + value["timeoutMilliseconds"] / 1000.0

    @staticmethod
    def _validated_snapshots(values):
        if type(values) not in (tuple, list) or not values:
            raise ComponentSnapshotWorkerError("invalid_worker_result")
        ordered = tuple(sorted(values, key=lambda item: (
            getattr(item, "serviceId", ""), getattr(item, "volumeId", ""))))
        if any(type(item) is not ComponentVolumeSnapshot for item in ordered):
            raise ComponentSnapshotWorkerError("invalid_worker_result")
        try:
            CoreBackupContract._component_payloads(ordered)
        except Exception:
            raise ComponentSnapshotWorkerError("invalid_worker_result") from None
        return ordered

    @staticmethod
    def _descriptor(snapshot):
        return {
            "serviceId": snapshot.serviceId,
            "serviceVersion": snapshot.serviceVersion,
            "configSchemaVersion": snapshot.configSchemaVersion,
            "dataSchemaVersion": snapshot.dataSchemaVersion,
            "volumeId": snapshot.volumeId,
            "byteLength": len(snapshot.payload),
            "sha256": hashlib.sha256(snapshot.payload).hexdigest(),
        }

    def _handle(self, connection):
        if self.peer_uid(connection) != self.client_uid:
            return
        read_deadline = self.monotonic() + 5
        request = _read_frame(connection, read_deadline)
        request_id, deadline = self._request(request, self.monotonic())
        with self.provider.quiesce(deadline) as values:
            snapshots = self._validated_snapshots(values)
            _write_frame(
                connection,
                {
                    "protocol": PROTOCOL,
                    "requestId": request_id,
                    "status": "ready",
                    "snapshots": [self._descriptor(item) for item in snapshots],
                },
                deadline,
            )
            for snapshot in snapshots:
                connection.settimeout(_remaining(deadline))
                connection.sendall(snapshot.payload)
            release = _read_frame(connection, deadline)
            if release != {
                "protocol": PROTOCOL,
                "requestId": request_id,
                "operation": "release",
            }:
                raise ComponentSnapshotWorkerError("invalid_worker_result")
            _write_frame(
                connection,
                {
                    "protocol": PROTOCOL,
                    "requestId": request_id,
                    "status": "released",
                },
                deadline,
            )
        self.completed += 1

    def _bind(self):
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(str(self.path))
            os.chmod(self.path, 0o600)
            if self.owner_uid != os.getuid():
                os.chown(self.path, self.owner_uid, -1)
            info = self.path.lstat()
            if (
                not stat.S_ISSOCK(info.st_mode)
                or info.st_uid != self.owner_uid
                or stat.S_IMODE(info.st_mode) != 0o600
                or info.st_nlink != 1
            ):
                raise OSError()
            listener.listen(1)
            listener.settimeout(0.2)
            self._listener = listener
            self._identity = (info.st_dev, info.st_ino)
            self._ready.set()
            return listener
        except Exception:
            listener.close()
            self._cleanup_socket()
            raise ValueError("invalid_worker_configuration") from None

    def _serve(self, *, one_shot):
        with self._lock:
            if self._listener is not None or self._stop.is_set():
                raise RuntimeError("worker_unavailable")
            listener = self._bind()
        try:
            while not self._stop.is_set():
                try:
                    connection, _ = listener.accept()
                except TimeoutError:
                    continue
                except OSError:
                    return
                with connection:
                    try:
                        self._handle(connection)
                    except (
                        ComponentSnapshotWorkerError,
                        OSError,
                        RuntimeError,
                        TypeError,
                        ValueError,
                    ):
                        pass
                if one_shot:
                    return
        finally:
            with self._lock:
                if self._listener is listener:
                    self._listener = None
            listener.close()
            self._cleanup_socket()

    def serve_once(self):
        self._serve(one_shot=True)

    def serve_forever(self):
        self._serve(one_shot=False)

    def _cleanup_socket(self):
        identity = self._identity
        if identity is None:
            return
        try:
            info = self.path.lstat()
            if (
                stat.S_ISSOCK(info.st_mode)
                and info.st_uid == self.owner_uid
                and (info.st_dev, info.st_ino) == identity
            ):
                self.path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass
        finally:
            self._identity = None

    def close(self):
        self._stop.set()
        with self._lock:
            listener = self._listener
        if listener is not None:
            listener.close()
        self._cleanup_socket()
