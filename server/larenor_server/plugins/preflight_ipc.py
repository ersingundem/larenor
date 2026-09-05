"""Bounded read-only Unix worker protocol. No Docker or install command exists."""

import fcntl
import json
import os
from pathlib import Path
import re
import socket
import stat
import struct
import threading
import time
import uuid

from .catalog import load_catalog, verify_plan
from .preflight_models import PreflightResult
from .models import InstallPlan
from .worker import _safe_path, DockerWorkerError


MAX_PACKET = 65536
ID = re.compile(r"[0-9a-f]{32}\Z")


class PreflightIPCError(Exception):
    def __init__(self, code="worker_unavailable"):
        self.code = code if code in {"worker_unavailable", "invalid_request", "invalid_worker_result"} else "worker_unavailable"
        super().__init__(self.code)


def _peer_uid(connection):
    if not hasattr(socket, "SO_PEERCRED"):
        raise PreflightIPCError()
    return struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]


def _timeout(connection, deadline):
    left = deadline - time.monotonic()
    if left <= 0:
        raise PreflightIPCError()
    connection.settimeout(left)


def _receive(connection, count, deadline):
    parts = bytearray()
    while len(parts) < count:
        _timeout(connection, deadline)
        part = connection.recv(count - len(parts))
        if not part:
            raise PreflightIPCError()
        parts.extend(part)
    return bytes(parts)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise PreflightIPCError("invalid_request")
        result[key] = value
    return result


def read_packet(connection, deadline):
    try:
        count = struct.unpack("!I", _receive(connection, 4, deadline))[0]
        if not 1 <= count <= MAX_PACKET:
            raise PreflightIPCError("invalid_request")
        body = json.loads(_receive(connection, count, deadline).decode("utf-8"), object_pairs_hook=_pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        if (type(body) is not dict or type(body.get("protocol")) is not int or body["protocol"] != 1
                or type(body.get("requestId")) is not str or not ID.fullmatch(body["requestId"])):
            raise PreflightIPCError("invalid_request")
        return body
    except (OSError, ValueError, UnicodeError, RecursionError, struct.error):
        raise PreflightIPCError("invalid_request") from None


def write_packet(connection, body, deadline):
    try:
        raw = json.dumps(body, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode("ascii")
        if len(raw) > MAX_PACKET:
            raise PreflightIPCError("invalid_request")
        _timeout(connection, deadline)
        connection.sendall(struct.pack("!I", len(raw)) + raw)
    except (OSError, ValueError, TypeError, RecursionError):
        raise PreflightIPCError("invalid_request") from None


class PreflightWorkerClient:
    def __init__(self, path, *, owner_uid=0, peer_uid=None, timeout=5):
        if type(owner_uid) is not int or owner_uid < 0 or type(timeout) not in (int, float) or not 0 < timeout <= 5:
            raise PreflightIPCError()
        self.path = Path(path).absolute()
        self.owner_uid, self.peer_uid, self.timeout = owner_uid, peer_uid or _peer_uid, timeout

    def _exchange(self, operation, plan=None):
        try:
            _safe_path(self.path, uid=self.owner_uid, kind=stat.S_ISSOCK)
            deadline = time.monotonic() + self.timeout
            request = {"protocol": 1, "requestId": uuid.uuid4().hex, "operation": operation}
            if plan is not None:
                request["plan"] = plan.model_dump(mode="json")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                _timeout(connection, deadline)
                connection.connect(str(self.path))
                if self.peer_uid(connection) != self.owner_uid:
                    raise PreflightIPCError()
                write_packet(connection, request, deadline)
                response = read_packet(connection, deadline)
            if response["requestId"] != request["requestId"]:
                raise PreflightIPCError("invalid_worker_result")
            if set(response) == {"protocol", "requestId", "error"}:
                raise PreflightIPCError()
            if set(response) != {"protocol", "requestId", "result"}:
                raise PreflightIPCError("invalid_worker_result")
            return response["result"]
        except (OSError, ValueError, DockerWorkerError):
            raise PreflightIPCError() from None

    def status(self):
        result = self._exchange("status")
        if (type(result) is not dict or set(result) != {"capability", "installationAvailable", "catalogDigest", "platform"}
                or result["capability"] != "preflight" or result["installationAvailable"] is not False
                or result["platform"] not in ("linux/amd64", "linux/arm64")
                or result["catalogDigest"] != load_catalog().digest):
            raise PreflightIPCError("invalid_worker_result")
        return result

    def inspect(self, plan):
        try:
            verified = verify_plan(plan, load_catalog())
            observed = PreflightResult.model_validate(self._exchange("inspect", verified))
            if (observed.catalogDigest, observed.planHash, observed.platform) != (
                    verified.catalogDigest, verified.planHash, verified.image.platform):
                raise PreflightIPCError("invalid_worker_result")
            return observed
        except (ValueError, TypeError):
            raise PreflightIPCError("invalid_worker_result") from None


class PreflightWorkerServer:
    def __init__(self, path, inspector, *, platform, allowed_uid, socket_gid=None, peer_uid=None, timeout=5):
        if (platform not in ("linux/amd64", "linux/arm64") or type(allowed_uid) is not int or allowed_uid < 0
                or socket_gid is not None and (type(socket_gid) is not int or socket_gid < 0)
                or type(timeout) not in (int, float) or not 0 < timeout <= 5):
            raise PreflightIPCError()
        self.path, self.inspector = Path(path).absolute(), inspector
        self.platform, self.allowed_uid, self.socket_gid = platform, allowed_uid, socket_gid
        self.peer_uid, self.timeout = peer_uid or _peer_uid, timeout
        self.catalog = load_catalog()
        self._listener = self._thread = self._lock = self._identity = None
        self._stopped = threading.Event()
        self._connection_lock = threading.Lock()
        self._active = None

    def start(self):
        # An invalid second start must not tear down an existing instance.
        if self._listener is not None or self._lock is not None:
            raise PreflightIPCError()
        try:
            _safe_path(self.path.parent, uid=os.getuid(), kind=stat.S_ISDIR)
            lock_path = self.path.parent / (self.path.name + ".lock")
            descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            self._lock = descriptor
            _safe_path(lock_path, uid=os.getuid(), kind=stat.S_ISREG, private=True)
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            # A matching UID is not worker ownership. A pre-existing endpoint
            # requires operator/runtime-directory recovery, never blind unlink.
            if self.path.exists() or self.path.is_symlink():
                raise PreflightIPCError()
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self._listener = listener
            listener.bind(str(self.path))
            if self.socket_gid is not None:
                os.chown(self.path, -1, self.socket_gid)
            os.chmod(self.path, 0o660 if self.socket_gid is not None else 0o600)
            info = self.path.lstat()
            self._identity = (info.st_dev, info.st_ino)
            listener.listen(4)
            listener.settimeout(.2)
            self._stopped.clear()
            self._thread = threading.Thread(target=self._serve, name="larenor-preflight", daemon=True)
            self._thread.start()
        except (OSError, RuntimeError, DockerWorkerError, PreflightIPCError):
            self.close()
            raise PreflightIPCError() from None

    def _answer(self, request):
        operation = request.get("operation")
        if operation == "status" and set(request) == {"protocol", "requestId", "operation"}:
            return {"capability": "preflight", "installationAvailable": False,
                    "catalogDigest": self.catalog.digest, "platform": self.platform}
        if operation != "inspect" or set(request) != {"protocol", "requestId", "operation", "plan"}:
            raise PreflightIPCError("invalid_request")
        try:
            selected = verify_plan(InstallPlan.model_validate_json(json.dumps(request["plan"], allow_nan=False)), self.catalog)
        except (ValueError, TypeError):
            raise PreflightIPCError("invalid_request") from None
        result = PreflightResult.model_validate(self.inspector.inspect(selected))
        if (result.catalogDigest, result.planHash, result.platform) != (selected.catalogDigest, selected.planHash, selected.image.platform):
            raise PreflightIPCError("invalid_worker_result")
        return result.model_dump(mode="json")

    def _serve(self):
        while not self._stopped.is_set():
            try:
                connection, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with connection:
                with self._connection_lock:
                    if self._stopped.is_set():
                        break
                    self._active = connection
                deadline = time.monotonic() + self.timeout
                try:
                    if self.peer_uid(connection) != self.allowed_uid:
                        continue
                    request = read_packet(connection, deadline)
                    try:
                        result = self._answer(request)
                        response = {"protocol": 1, "requestId": request["requestId"], "result": result}
                    except Exception as error:
                        code = error.code if isinstance(error, PreflightIPCError) and error.code == "invalid_request" else "worker_unavailable"
                        response = {"protocol": 1, "requestId": request["requestId"], "error": code}
                    write_packet(connection, response, deadline)
                except (OSError, PreflightIPCError):
                    pass
                finally:
                    with self._connection_lock:
                        self._active = None

    def close(self):
        self._stopped.set()
        if self._listener is not None:
            self._listener.close()
        with self._connection_lock:
            if self._active is not None:
                try:
                    self._active.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        if self._thread is not None and self._thread.ident is not None:
            self._thread.join(self.timeout + .5)
            if self._thread.is_alive():
                # A blocked filesystem observation must not let a replacement
                # daemon acquire this process's worker identity concurrently.
                raise PreflightIPCError()
        if self._identity is not None:
            try:
                info = self.path.lstat()
                if (info.st_dev, info.st_ino) == self._identity and stat.S_ISSOCK(info.st_mode):
                    self.path.unlink()
            except FileNotFoundError:
                pass
        if self._lock is not None:
            os.close(self._lock)
        self._listener = self._thread = self._lock = self._identity = None
