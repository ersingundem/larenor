"""Private bounded IPC boundary for packaged Proxmox power effects.

The public Core sends only the already-authorized opaque guest binding and its
exact revision snapshot.  Host names, URLs and credentials stay behind the
worker's packaged adapter boundary.  The default adapter performs no effect.
"""

from collections import deque
from dataclasses import dataclass
import fcntl
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import socket
import stat
import struct
import threading
import time
import uuid

from ..plugins.worker import DockerWorkerError, _safe_path
from .models import PreviewRequest, ProxmoxGuestDescriptor, ProxmoxPowerEffectResult


PROTOCOL = 1
MAX_PACKET = 16_384
MAX_SEEN_REQUESTS = 256
EFFECT_ACTIONS = frozenset({"start", "shutdown", "stop", "reboot", "reset"})
_ID = re.compile(r"[0-9a-f]{32}\Z")
_OPAQUE = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
_UPID_HASH = re.compile(r"UPID-SHA256:[0-9a-f]{64}\Z")
_TARGET = {
    "start": "running",
    "shutdown": "stopped",
    "stop": "stopped",
    "reboot": "running",
    "reset": "running",
}
_SOURCE = {
    "start": frozenset({"stopped"}),
    "shutdown": frozenset({"running"}),
    "stop": frozenset({"running"}),
    "reboot": frozenset({"running"}),
    "reset": frozenset({"running"}),
}


class ProxmoxPowerWorkerError(Exception):
    """Static fail-closed boundary; private worker details never escape."""

    def __init__(self, code="worker_unavailable"):
        self.code = code if code in {"worker_unavailable", "invalid_request", "invalid_worker_result"} else "worker_unavailable"
        super().__init__(self.code)


@dataclass(frozen=True)
class PackagedProxmoxCommand:
    request_id: str
    action: str
    resource_id: str
    user_revision: int
    resource_revision: int
    acl_revision: int
    binding_id: str
    binding_revision: int
    service_id: str
    service_revision: int
    guest_kind: str
    current_state: str
    status_revision: int
    allowed_addresses: tuple[str, ...]


@dataclass(frozen=True)
class PackagedProxmoxApiResult:
    """Private adapter result. Raw UPID must never cross the worker boundary."""

    outcome: str
    state: str
    status_revision: int
    upid: str | None = None

    def __repr__(self):
        return (
            "PackagedProxmoxApiResult(outcome=%r, state=%r, status_revision=%r, "
            "upid=<redacted>)"
            % (self.outcome, self.state, self.status_revision)
        )


class UnavailableProxmoxApiAdapter:
    """Production-safe default until an owned packaged adapter is configured."""

    def execute(self, _command, *, deadline, cancelled):
        raise ProxmoxPowerWorkerError()


def _peer_uid(connection):
    if not hasattr(socket, "SO_PEERCRED"):
        raise ProxmoxPowerWorkerError()
    return struct.unpack(
        "3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
    )[1]


def _remaining(deadline):
    left = deadline - time.monotonic()
    if not math.isfinite(deadline) or left <= 0:
        raise ProxmoxPowerWorkerError()
    return left


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProxmoxPowerWorkerError("invalid_request")
        result[key] = value
    return result


def _receive(connection, count, deadline, guard=None):
    parts = bytearray()
    while len(parts) < count:
        if guard is not None:
            try:
                guard()
            except BaseException as error:
                if isinstance(error, (KeyboardInterrupt, SystemExit)):
                    raise
                raise ProxmoxPowerWorkerError() from None
        left = _remaining(deadline)
        connection.settimeout(min(left, 0.05) if guard is not None else left)
        try:
            part = connection.recv(count - len(parts))
        except socket.timeout:
            if guard is not None:
                continue
            raise ProxmoxPowerWorkerError() from None
        if not part:
            raise ProxmoxPowerWorkerError()
        parts.extend(part)
    return bytes(parts)


def _read_packet(connection, deadline, guard=None):
    try:
        count = struct.unpack("!I", _receive(connection, 4, deadline, guard))[0]
        if not 1 <= count <= MAX_PACKET:
            raise ProxmoxPowerWorkerError("invalid_request")
        value = json.loads(
            _receive(connection, count, deadline, guard).decode("utf-8"),
            object_pairs_hook=_pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
        if (
            type(value) is not dict
            or value.get("protocol") != PROTOCOL
            or type(value.get("protocol")) is not int
            or type(value.get("requestId")) is not str
            or _ID.fullmatch(value["requestId"]) is None
        ):
            raise ProxmoxPowerWorkerError("invalid_request")
        return value
    except ProxmoxPowerWorkerError:
        raise
    except (OSError, ValueError, TypeError, UnicodeError, RecursionError, struct.error):
        raise ProxmoxPowerWorkerError("invalid_request") from None


def _write_packet(connection, value, deadline):
    try:
        raw = json.dumps(
            value, separators=(",", ":"), ensure_ascii=True, allow_nan=False
        ).encode("ascii")
        if not 1 <= len(raw) <= MAX_PACKET:
            raise ProxmoxPowerWorkerError("invalid_request")
        connection.settimeout(_remaining(deadline))
        connection.sendall(struct.pack("!I", len(raw)) + raw)
    except ProxmoxPowerWorkerError:
        raise
    except (OSError, ValueError, TypeError, RecursionError):
        raise ProxmoxPowerWorkerError("invalid_request") from None


def _revision(value):
    return type(value) is int and 1 <= value <= 2**63 - 1


def _allowed_address(value):
    try:
        address = ipaddress.ip_address(value)
    except (ValueError, TypeError):
        return False
    if str(address) != value or address.is_link_local or address.is_multicast:
        return False
    return (
        address.is_loopback
        or address.version == 4 and any(address in network for network in (
            ipaddress.ip_network("10.0.0.0/8"),
            ipaddress.ip_network("172.16.0.0/12"),
            ipaddress.ip_network("192.168.0.0/16"),
        ))
        or address.version == 6 and address in ipaddress.ip_network("fc00::/7")
    )


def _wire_command(descriptor, action, preview, deadline_ms, allowed_addresses):
    if (
        not isinstance(descriptor, ProxmoxGuestDescriptor)
        or not isinstance(preview, PreviewRequest)
        or action not in EFFECT_ACTIONS
        or action != preview.action
        or descriptor.binding_id != preview.expectedBindingId
        or descriptor.binding_revision != preview.expectedBindingRevision
        or descriptor.service_id != preview.expectedServiceId
        or descriptor.service_revision != preview.expectedServiceRevision
        or descriptor.guest_kind != preview.expectedGuestKind
        or descriptor.status != preview.expectedCurrentState
        or descriptor.status_revision != preview.expectedStatusRevision
        or type(deadline_ms) is not int
        or not 500 <= deadline_ms <= 30_000
        or type(allowed_addresses) is not tuple
        or not 1 <= len(allowed_addresses) <= 8
        or len(set(allowed_addresses)) != len(allowed_addresses)
        or any(not _allowed_address(value) for value in allowed_addresses)
    ):
        raise ProxmoxPowerWorkerError()
    return {
        "schemaVersion": 1,
        "requestId": preview.requestId,
        "action": action,
        "resourceId": descriptor.resource_id,
        "userRevision": preview.expectedUserRevision,
        "resourceRevision": preview.expectedResourceRevision,
        "aclRevision": preview.expectedAclRevision,
        "bindingId": descriptor.binding_id,
        "bindingRevision": descriptor.binding_revision,
        "serviceId": descriptor.service_id,
        "serviceRevision": descriptor.service_revision,
        "guestKind": descriptor.guest_kind,
        "currentState": descriptor.status,
        "statusRevision": descriptor.status_revision,
        "allowedAddresses": sorted(allowed_addresses),
        "deadlineMs": deadline_ms,
    }


def _command(value):
    keys = {
        "schemaVersion", "requestId", "action", "resourceId",
        "userRevision", "resourceRevision", "aclRevision", "bindingId",
        "bindingRevision", "serviceId", "serviceRevision", "guestKind",
        "currentState", "statusRevision", "allowedAddresses", "deadlineMs",
    }
    if (
        type(value) is not dict
        or set(value) != keys
        or value["schemaVersion"] != 1
        or type(value["schemaVersion"]) is not int
        or type(value["requestId"]) is not str
        or _ID.fullmatch(value["requestId"]) is None
        or value["action"] not in EFFECT_ACTIONS
        or type(value["resourceId"]) is not str
        or _ID.fullmatch(value["resourceId"]) is None
        or any(not _revision(value[key]) for key in (
            "userRevision", "resourceRevision", "aclRevision",
            "bindingRevision", "serviceRevision", "statusRevision",
        ))
        or any(type(value[key]) is not str or _OPAQUE.fullmatch(value[key]) is None
               for key in ("bindingId", "serviceId"))
        or value["guestKind"] not in {"qemu", "lxc"}
        or value["currentState"] not in {"running", "stopped", "suspended"}
        or value["currentState"] not in _SOURCE[value["action"]]
        or type(value["allowedAddresses"]) is not list
        or not 1 <= len(value["allowedAddresses"]) <= 8
        or value["allowedAddresses"] != sorted(set(value["allowedAddresses"]))
        or any(not _allowed_address(address) for address in value["allowedAddresses"])
        or type(value["deadlineMs"]) is not int
        or not 500 <= value["deadlineMs"] <= 30_000
    ):
        raise ProxmoxPowerWorkerError("invalid_request")
    return PackagedProxmoxCommand(
        request_id=value["requestId"], action=value["action"],
        resource_id=value["resourceId"], user_revision=value["userRevision"],
        resource_revision=value["resourceRevision"], acl_revision=value["aclRevision"],
        binding_id=value["bindingId"], binding_revision=value["bindingRevision"],
        service_id=value["serviceId"], service_revision=value["serviceRevision"],
        guest_kind=value["guestKind"], current_state=value["currentState"],
        status_revision=value["statusRevision"],
        allowed_addresses=tuple(value["allowedAddresses"]),
    )


def _wire_result(value, command):
    if (
        not isinstance(value, PackagedProxmoxApiResult)
        or value.outcome not in {"succeeded", "failed", "cancelled", "unknown"}
        or value.state not in {"running", "stopped", "suspended"}
        or not _revision(value.status_revision)
    ):
        raise ProxmoxPowerWorkerError("invalid_worker_result")
    if value.outcome == "succeeded":
        if (
            value.state != _TARGET[command.action]
            or value.status_revision != command.status_revision + 1
            or type(value.upid) is not str
            or not 1 <= len(value.upid.encode("utf-8")) <= 512
            or any(ord(char) < 32 or ord(char) == 127 for char in value.upid)
        ):
            raise ProxmoxPowerWorkerError("invalid_worker_result")
        operation_ref = "UPID-SHA256:" + hashlib.sha256(
            value.upid.encode("utf-8")
        ).hexdigest()
    elif value.outcome == "unknown" and value.upid is not None:
        if (
            value.state != command.current_state
            or value.status_revision != command.status_revision
            or type(value.upid) is not str
            or not 1 <= len(value.upid.encode("utf-8")) <= 512
            or not value.upid.startswith("UPID:")
            or any(ord(char) < 32 or ord(char) == 127 for char in value.upid)
        ):
            raise ProxmoxPowerWorkerError("invalid_worker_result")
        operation_ref = "UPID-SHA256:" + hashlib.sha256(
            value.upid.encode("utf-8")
        ).hexdigest()
    else:
        if (
            value.upid is not None
            or value.state != command.current_state
            or value.status_revision != command.status_revision
        ):
            raise ProxmoxPowerWorkerError("invalid_worker_result")
        operation_ref = None
    return {
        "outcome": value.outcome,
        "state": value.state,
        "statusRevision": value.status_revision,
        "operationRef": operation_ref,
    }


def _result(value):
    if (
        type(value) is not dict
        or set(value) != {"outcome", "state", "statusRevision", "operationRef"}
        or value["outcome"] not in {"succeeded", "failed", "cancelled", "unknown"}
        or value["state"] not in {"running", "stopped", "suspended"}
        or not _revision(value["statusRevision"])
        or (value["operationRef"] is not None and (
            type(value["operationRef"]) is not str
            or _UPID_HASH.fullmatch(value["operationRef"]) is None
        ))
    ):
        raise ProxmoxPowerWorkerError("invalid_worker_result")
    return ProxmoxPowerEffectResult(
        value["outcome"], value["state"], value["statusRevision"],
        value["operationRef"],
    )


class ProxmoxPowerWorkerClient:
    def __init__(
        self, path, *, owner_uid=0, peer_uid=None, timeout=5,
        expected_identity=None,
    ):
        if (
            type(owner_uid) is not int or owner_uid < 0
            or type(timeout) not in (int, float) or isinstance(timeout, bool)
            or not 0 < timeout <= 30
            or expected_identity is not None and (
                type(expected_identity) is not tuple
                or len(expected_identity) != 2
                or any(type(value) is not int or value < 0
                       for value in expected_identity)
            )
        ):
            raise ProxmoxPowerWorkerError()
        self.path = Path(path).absolute()
        self.owner_uid = owner_uid
        self.peer_uid = peer_uid or _peer_uid
        self.timeout = timeout
        self.expected_identity = expected_identity

    def execute_bounded(
        self, descriptor, action, guard, *, preview, deadline_ms,
        allowed_addresses, continuation_guard=None,
    ):
        if not callable(guard) or (
            continuation_guard is not None and not callable(continuation_guard)
        ):
            raise ProxmoxPowerWorkerError()
        continuing = continuation_guard or guard
        command = _wire_command(
            descriptor, action, preview, deadline_ms, tuple(allowed_addresses)
        )
        try:
            guard()
            selected = _safe_path(
                self.path, uid=self.owner_uid, kind=stat.S_ISSOCK, private=True
            )
            info = selected.lstat()
            if (
                self.expected_identity is not None
                and (info.st_dev, info.st_ino) != self.expected_identity
            ):
                raise ProxmoxPowerWorkerError()
            deadline = time.monotonic() + min(self.timeout, deadline_ms / 1000)
            envelope_id = uuid.uuid4().hex
            request = {
                "protocol": PROTOCOL,
                "requestId": envelope_id,
                "operation": "execute",
                "command": command,
            }
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(_remaining(deadline))
                connection.connect(str(self.path))
                if self.peer_uid(connection) != self.owner_uid:
                    raise ProxmoxPowerWorkerError()
                _write_packet(connection, request, deadline)
                response = _read_packet(connection, deadline, continuing)
            if response["requestId"] != envelope_id:
                raise ProxmoxPowerWorkerError("invalid_worker_result")
            if set(response) == {"protocol", "requestId", "error"}:
                raise ProxmoxPowerWorkerError()
            if set(response) != {"protocol", "requestId", "result"}:
                raise ProxmoxPowerWorkerError("invalid_worker_result")
            continuing()
            return _result(response["result"])
        except BaseException as error:
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            if isinstance(error, ProxmoxPowerWorkerError):
                raise ProxmoxPowerWorkerError(error.code) from None
            if isinstance(error, (OSError, ValueError, TypeError, RuntimeError, DockerWorkerError)):
                raise ProxmoxPowerWorkerError() from None
            raise


def verified_power_worker_client(
    socket_path, health_path, owner_uid, *, peer_uid=None, timeout=5,
):
    """Return an inode-bound client only for an exact live health receipt."""
    try:
        from .worker_runtime import read_health_receipt

        selected = _safe_path(
            Path(socket_path), uid=owner_uid, kind=stat.S_ISSOCK, private=True
        )
        info = selected.lstat()
        receipt = read_health_receipt(Path(health_path))
        identity = (info.st_dev, info.st_ino)
        if (
            receipt.state != "ready"
            or receipt.worker_uid != owner_uid
            or (receipt.socket_device, receipt.socket_inode) != identity
        ):
            return None
        return ProxmoxPowerWorkerClient(
            selected, owner_uid=owner_uid, peer_uid=peer_uid, timeout=timeout,
            expected_identity=identity,
        )
    except BaseException as error:
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        return None


class ProxmoxPowerWorkerServer:
    def __init__(self, path, adapter=None, *, allowed_uid, peer_uid=None, timeout=5):
        if (
            type(allowed_uid) is not int or allowed_uid < 0
            or type(timeout) not in (int, float) or isinstance(timeout, bool)
            or not 0 < timeout <= 30
        ):
            raise ProxmoxPowerWorkerError()
        self.path = Path(path).absolute()
        self.adapter = adapter or UnavailableProxmoxApiAdapter()
        self.allowed_uid = allowed_uid
        self.peer_uid = peer_uid or _peer_uid
        self.timeout = timeout
        self._listener = self._thread = self._lock_file = self._identity = None
        self._stopped = threading.Event()
        self._active_lock = threading.Lock()
        self._active = None
        self._seen = set()
        self._seen_order = deque()

    def start(self):
        if self._listener is not None or self._lock_file is not None:
            raise ProxmoxPowerWorkerError()
        try:
            _safe_path(self.path.parent, uid=os.getuid(), kind=stat.S_ISDIR)
            lock_path = self.path.parent / (self.path.name + ".lock")
            descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            self._lock_file = descriptor
            _safe_path(lock_path, uid=os.getuid(), kind=stat.S_ISREG, private=True)
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if self.path.exists() or self.path.is_symlink():
                raise ProxmoxPowerWorkerError()
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self._listener = listener
            listener.bind(str(self.path))
            info = self.path.lstat()
            self._identity = (info.st_dev, info.st_ino)
            os.chmod(self.path, 0o600)
            listener.listen(4)
            listener.settimeout(0.1)
            self._stopped.clear()
            self._thread = threading.Thread(
                target=self._serve, name="larenor-proxmox-power", daemon=True
            )
            self._thread.start()
        except BaseException as error:
            try:
                self.close()
            except Exception:
                pass
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            raise ProxmoxPowerWorkerError() from None

    def _remember(self, request_id):
        if request_id in self._seen:
            raise ProxmoxPowerWorkerError("invalid_request")
        self._seen.add(request_id)
        self._seen_order.append(request_id)
        while len(self._seen_order) > MAX_SEEN_REQUESTS:
            self._seen.discard(self._seen_order.popleft())

    def _cancelled(self, connection, deadline):
        if self._stopped.is_set() or time.monotonic() >= deadline:
            return True
        try:
            connection.setblocking(False)
            try:
                return connection.recv(1, socket.MSG_PEEK) == b""
            except BlockingIOError:
                return False
            finally:
                connection.setblocking(True)
        except OSError:
            return True

    def _answer(self, request, connection, deadline):
        if (
            set(request) != {"protocol", "requestId", "operation", "command"}
            or request["operation"] != "execute"
        ):
            raise ProxmoxPowerWorkerError("invalid_request")
        raw = request["command"]
        command = _command(raw)
        self._remember(command.request_id)
        worker_deadline = min(
            deadline, time.monotonic() + raw["deadlineMs"] / 1000
        )
        if self._cancelled(connection, worker_deadline):
            raise ProxmoxPowerWorkerError()
        value = self.adapter.execute(
            command,
            deadline=worker_deadline,
            cancelled=lambda: self._cancelled(connection, worker_deadline),
        )
        if self._cancelled(connection, worker_deadline):
            raise ProxmoxPowerWorkerError()
        return _wire_result(value, command)

    def _serve(self):
        while not self._stopped.is_set():
            try:
                connection, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with connection:
                with self._active_lock:
                    if self._stopped.is_set():
                        break
                    self._active = connection
                deadline = time.monotonic() + self.timeout
                try:
                    if self.peer_uid(connection) != self.allowed_uid:
                        continue
                    request = _read_packet(connection, deadline)
                    try:
                        result = self._answer(request, connection, deadline)
                        response = {
                            "protocol": PROTOCOL,
                            "requestId": request["requestId"],
                            "result": result,
                        }
                    except Exception as error:
                        code = (
                            error.code
                            if isinstance(error, ProxmoxPowerWorkerError)
                            and error.code == "invalid_request"
                            else "worker_unavailable"
                        )
                        response = {
                            "protocol": PROTOCOL,
                            "requestId": request["requestId"],
                            "error": code,
                        }
                    _write_packet(connection, response, deadline)
                except (OSError, ProxmoxPowerWorkerError):
                    pass
                finally:
                    with self._active_lock:
                        self._active = None

    def close(self):
        self._stopped.set()
        if self._listener is not None:
            self._listener.close()
        with self._active_lock:
            if self._active is not None:
                try:
                    self._active.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        if self._thread is not None and self._thread.ident is not None:
            self._thread.join(self.timeout + 0.5)
            if self._thread.is_alive():
                raise ProxmoxPowerWorkerError()
        if self._identity is not None:
            try:
                info = self.path.lstat()
                if (
                    (info.st_dev, info.st_ino) == self._identity
                    and stat.S_ISSOCK(info.st_mode)
                ):
                    self.path.unlink()
            except FileNotFoundError:
                pass
        if self._lock_file is not None:
            os.close(self._lock_file)
        self._listener = self._thread = self._lock_file = self._identity = None
        self._seen.clear()
        self._seen_order.clear()
