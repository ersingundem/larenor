"""Bounded, read-only Proxmox telemetry over a short-lived credential lease.

The observer has no runtime URL, node, guest or credential input.  A service
issuer opens one sealed binding for a single poll and clears its mutable
credential buffer when the worker-side observation finishes.
"""

from dataclasses import asdict, dataclass, replace
import hashlib
import json
import math
import re
import threading
import time

from ..services.transport import ProbeTransportError, ServiceTransport
from .api_adapter import ProxmoxServiceBinding, load_service_binding


MAX_RESPONSE_BYTES = 65_536
MAX_POLL_SECONDS = 10
MAX_STALE_SECONDS = 300
_ID = re.compile(r"[0-9a-f]{32}\Z")
_OPAQUE = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
_NODE = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?\Z")
_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._ -]{0,127}\Z")
_UPID = re.compile(r"UPID:[^\x00-\x20\x7f]{1,507}\Z")
_TASK_TYPE = re.compile(r"[A-Za-z0-9._-]{1,64}\Z")
_TASK_STATE = {
    "OK": "succeeded",
    "running": "executing",
    "stopped": "failed",
    "ERROR": "failed",
    "unknown": "unknown",
}


class CredentialLeaseError(Exception):
    """Stable error without path, endpoint or credential details."""

    def __init__(self, code="lease_unavailable"):
        self.code = code if code in {
            "lease_unavailable", "binding_changed",
        } else "lease_unavailable"
        super().__init__(self.code)


class TelemetrySchemaError(Exception):
    pass


def _revision(value):
    return type(value) is int and 1 <= value <= 2**63 - 1


@dataclass(frozen=True, repr=False)
class TelemetryExpectation:
    resource_id: str
    resource_revision: int
    binding_id: str
    binding_revision: int
    service_id: str
    service_revision: int
    node: str
    node_revision: int
    guest_revisions: tuple[tuple[str, int, int], ...]

    def __post_init__(self):
        valid_guests = (
            type(self.guest_revisions) is tuple
            and 0 <= len(self.guest_revisions) <= 512
            and all(
                type(item) is tuple and len(item) == 3
                and item[0] in {"qemu", "lxc"}
                and type(item[1]) is int and 1 <= item[1] <= 999_999_999
                and _revision(item[2])
                for item in self.guest_revisions
            )
            and len({item[:2] for item in self.guest_revisions})
            == len(self.guest_revisions)
        )
        if (
            type(self.resource_id) is not str
            or _ID.fullmatch(self.resource_id) is None
            or not _revision(self.resource_revision)
            or any(
                type(value) is not str or _OPAQUE.fullmatch(value) is None
                for value in (self.binding_id, self.service_id)
            )
            or not _revision(self.binding_revision)
            or not _revision(self.service_revision)
            or type(self.node) is not str or _NODE.fullmatch(self.node) is None
            or not _revision(self.node_revision)
            or not valid_guests
        ):
            raise CredentialLeaseError("binding_changed")

    def __repr__(self):
        return (
            "TelemetryExpectation(resource_id=%r, resource_revision=%r, "
            "binding_id=%r, binding_revision=%r, service_id=%r, "
            "service_revision=%r, node=<redacted>, node_revision=%r, "
            "guest_revisions=<redacted>)"
            % (
                self.resource_id, self.resource_revision, self.binding_id,
                self.binding_revision, self.service_id, self.service_revision,
                self.node_revision,
            )
        )


class WorkerCredentialLease:
    """One poll-scoped credential whose owned backing bytes are cleared."""

    def __init__(self, binding, credential, expires_at, clock):
        self.scheme = binding.scheme
        self.host = binding.host
        self.port = binding.port
        self.pinned_address = binding.pinned_address
        self.node = binding.node
        self._credential = credential
        self._expires_at = expires_at
        self._clock = clock
        self._cleared = False
        self._lock = threading.Lock()

    def __repr__(self):
        return "WorkerCredentialLease(<private>)"

    @property
    def cleared(self):
        with self._lock:
            return self._cleared

    def authorization(self):
        with self._lock:
            if self._cleared or self._clock() >= self._expires_at:
                raise CredentialLeaseError()
            try:
                return self._credential.decode("utf-8")
            except UnicodeError:
                raise CredentialLeaseError() from None

    def check(self):
        with self._lock:
            if self._cleared or self._clock() >= self._expires_at:
                raise CredentialLeaseError()

    def close(self):
        with self._lock:
            if self._cleared:
                return
            for index in range(len(self._credential)):
                self._credential[index] = 0
            self.scheme = self.host = self.pinned_address = self.node = ""
            self.port = 0
            self._cleared = True

    def __enter__(self):
        self.check()
        return self

    def __exit__(self, *_args):
        self.close()

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass


class ServiceCredentialLeaseIssuer:
    """Service-side sealed binding holder issuing bounded worker leases."""

    def __init__(self, credential_path, key_path, *, clock=time.monotonic,
                 lease_ttl=2):
        if (
            not callable(clock)
            or type(lease_ttl) not in (int, float)
            or isinstance(lease_ttl, bool)
            or not math.isfinite(lease_ttl)
            or not 0.1 <= lease_ttl <= 10
        ):
            raise CredentialLeaseError()
        self._credential_path = credential_path
        self._key_path = key_path
        self._clock = clock
        self._lease_ttl = float(lease_ttl)

    def __repr__(self):
        return "ServiceCredentialLeaseIssuer(<private>)"

    @staticmethod
    def _matches(selected, expected):
        return (
            isinstance(selected, ProxmoxServiceBinding)
            and selected.resource_id == expected.resource_id
            and selected.resource_revision == expected.resource_revision
            and selected.binding_id == expected.binding_id
            and selected.binding_revision == expected.binding_revision
            and selected.service_id == expected.service_id
            and selected.service_revision == expected.service_revision
            and selected.node == expected.node
        )

    def issue(self, expected, *, deadline):
        if (
            not isinstance(expected, TelemetryExpectation)
            or type(deadline) not in (int, float)
            or isinstance(deadline, bool)
            or not math.isfinite(deadline)
        ):
            raise CredentialLeaseError("binding_changed")
        now = self._clock()
        if deadline <= now:
            raise CredentialLeaseError()
        try:
            selected = load_service_binding(
                self._credential_path, self._key_path,
            )
        except Exception:
            raise CredentialLeaseError() from None
        if not self._matches(selected, expected):
            raise CredentialLeaseError("binding_changed")
        credential = bytearray(b"PVEAPIToken=")
        credential.extend(selected.token_id.encode("utf-8"))
        credential.extend(b"=")
        credential.extend(selected.token_secret.encode("utf-8"))
        return WorkerCredentialLease(
            selected, credential, min(deadline, now + self._lease_ttl), self._clock,
        )


@dataclass(frozen=True)
class NodeTelemetry:
    revision: int
    cpu_ratio: float
    cpu_count: int
    memory_used: int
    memory_total: int
    disk_used: int
    disk_total: int
    network_rx: int
    network_tx: int
    uptime_seconds: int


@dataclass(frozen=True)
class GuestTelemetry:
    kind: str
    guest_id: int
    revision: int
    name: str
    status: str
    cpu_ratio: float
    cpu_count: int
    memory_used: int
    memory_total: int
    disk_used: int
    disk_total: int
    network_rx: int
    network_tx: int
    uptime_seconds: int


@dataclass(frozen=True)
class StorageTelemetry:
    name: str
    revision: int
    status: str
    used: int
    available: int
    total: int


@dataclass(frozen=True)
class TaskTelemetry:
    operation_ref: str
    kind: str
    status: str
    started_at: int
    ended_at: int | None


@dataclass(frozen=True)
class ProxmoxTelemetrySnapshot:
    availability: str
    resource_revision: int
    binding_revision: int
    service_revision: int
    observed_at: float
    polled_at: float
    node: NodeTelemetry | None
    guests: tuple[GuestTelemetry, ...]
    storages: tuple[StorageTelemetry, ...]
    tasks: tuple[TaskTelemetry, ...]

    def to_public(self):
        return asdict(self)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise TelemetrySchemaError()
        result[key] = value
    return result


def _integer(value, *, maximum=2**63 - 1):
    if type(value) is not int or not 0 <= value <= maximum:
        raise TelemetrySchemaError()
    return value


def _ratio(value):
    if type(value) not in (int, float) or isinstance(value, bool):
        raise TelemetrySchemaError()
    result = float(value)
    if not math.isfinite(result) or not 0 <= result <= 1:
        raise TelemetrySchemaError()
    return result


def _name(value):
    if type(value) is not str or _NAME.fullmatch(value) is None:
        raise TelemetrySchemaError()
    return value


def _object(value, keys):
    if type(value) is not dict or set(value) != set(keys):
        raise TelemetrySchemaError()
    return value


def _node(value, expected_revision):
    data = _object(value, {
        "revision", "cpu", "maxcpu", "mem", "maxmem", "rootfs",
        "maxrootfs", "netin", "netout", "uptime",
    })
    revision = data["revision"]
    if not _revision(revision) or revision != expected_revision:
        raise TelemetrySchemaError()
    return NodeTelemetry(
        revision, _ratio(data["cpu"]), _integer(data["maxcpu"], maximum=4096),
        _integer(data["mem"]), _integer(data["maxmem"]),
        _integer(data["rootfs"]), _integer(data["maxrootfs"]),
        _integer(data["netin"]), _integer(data["netout"]),
        _integer(data["uptime"]),
    )


def _guests(value, kind, expected):
    if type(value) is not list or len(value) > 512:
        raise TelemetrySchemaError()
    result = []
    revisions = {(item_kind, item_id): revision
                 for item_kind, item_id, revision in expected}
    for raw in value:
        data = _object(raw, {
            "vmid", "revision", "name", "status", "cpu", "maxcpu", "mem",
            "maxmem", "disk", "maxdisk", "netin", "netout", "uptime",
        })
        guest_id = _integer(data["vmid"], maximum=999_999_999)
        if guest_id < 1 or revisions.get((kind, guest_id)) != data["revision"]:
            raise TelemetrySchemaError()
        if data["status"] not in {"running", "stopped", "paused"}:
            raise TelemetrySchemaError()
        result.append(GuestTelemetry(
            kind, guest_id, data["revision"], _name(data["name"]), data["status"],
            _ratio(data["cpu"]), _integer(data["maxcpu"], maximum=4096),
            _integer(data["mem"]), _integer(data["maxmem"]),
            _integer(data["disk"]), _integer(data["maxdisk"]),
            _integer(data["netin"]), _integer(data["netout"]),
            _integer(data["uptime"]),
        ))
    if {(item.kind, item.guest_id) for item in result} != {
        (item_kind, item_id) for item_kind, item_id, _revision_value in expected
        if item_kind == kind
    }:
        raise TelemetrySchemaError()
    return tuple(sorted(result, key=lambda item: item.guest_id))


def _storages(value):
    if type(value) is not list or len(value) > 128:
        raise TelemetrySchemaError()
    result = []
    for raw in value:
        data = _object(raw, {
            "storage", "revision", "status", "used", "avail", "total",
        })
        if not _revision(data["revision"]) or data["status"] not in {
            "available", "offline",
        }:
            raise TelemetrySchemaError()
        result.append(StorageTelemetry(
            _name(data["storage"]), data["revision"], data["status"],
            _integer(data["used"]), _integer(data["avail"]),
            _integer(data["total"]),
        ))
    return tuple(sorted(result, key=lambda item: item.name))


def _tasks(value):
    if type(value) is not list or len(value) > 128:
        raise TelemetrySchemaError()
    result = []
    for raw in value:
        data = _object(raw, {"upid", "type", "status", "starttime", "endtime"})
        upid = data["upid"]
        if (
            type(upid) is not str or _UPID.fullmatch(upid) is None
            or type(data["type"]) is not str
            or _TASK_TYPE.fullmatch(data["type"]) is None
            or data["status"] not in _TASK_STATE
        ):
            raise TelemetrySchemaError()
        started = _integer(data["starttime"])
        ended = data["endtime"]
        if ended is not None:
            ended = _integer(ended)
            if ended < started:
                raise TelemetrySchemaError()
        result.append(TaskTelemetry(
            "UPID-SHA256:" + hashlib.sha256(upid.encode("utf-8")).hexdigest(),
            data["type"], _TASK_STATE[data["status"]], started, ended,
        ))
    return tuple(result)


class ProxmoxTelemetryObserver:
    """Single-flight five-request observer with a bounded stale cache."""

    def __init__(self, issuer, *, clock=time.time, monotonic=time.monotonic,
                 resolver=None, connector=None, max_stale_seconds=30):
        if (
            not isinstance(issuer, ServiceCredentialLeaseIssuer)
            or not callable(clock) or not callable(monotonic)
            or resolver is not None and not callable(resolver)
            or connector is not None and not callable(connector)
            or type(max_stale_seconds) not in (int, float)
            or isinstance(max_stale_seconds, bool)
            or not math.isfinite(max_stale_seconds)
            or not 0 <= max_stale_seconds <= MAX_STALE_SECONDS
        ):
            raise CredentialLeaseError()
        self._issuer = issuer
        self._clock = clock
        self._monotonic = monotonic
        self._resolver = resolver
        self._connector = connector
        self._max_stale_seconds = float(max_stale_seconds)
        self._poll_lock = threading.Lock()
        self._cache = None
        self._cache_expectation = None

    def __repr__(self):
        return "ProxmoxTelemetryObserver(<private>)"

    @staticmethod
    def _empty(availability, expected, now):
        return ProxmoxTelemetrySnapshot(
            availability, expected.resource_revision, expected.binding_revision,
            expected.service_revision, now, now, None, (), (), (),
        )

    def _unavailable(self, expected, now):
        cached = self._cache
        if (
            cached is not None
            and self._cache_expectation == expected
            and self._max_stale_seconds > 0
            and now - cached.observed_at <= self._max_stale_seconds
        ):
            return replace(cached, availability="stale", polled_at=now)
        return self._empty("offline", expected, now)

    def poll(self, expected, *, deadline, cancelled):
        now = self._clock()
        if not isinstance(expected, TelemetryExpectation):
            raise CredentialLeaseError("binding_changed")
        if (
            not callable(cancelled)
            or type(deadline) not in (int, float)
            or isinstance(deadline, bool)
            or not math.isfinite(deadline)
        ):
            return self._empty("schema_drift", expected, now)
        if not self._poll_lock.acquire(blocking=False):
            return self._unavailable(expected, now)
        lease = None
        try:
            logical_start = self._monotonic()
            logical_deadline = min(deadline, logical_start + MAX_POLL_SECONDS)

            def gate():
                if self._monotonic() >= logical_deadline or cancelled():
                    raise CredentialLeaseError()
                if lease is not None:
                    lease.check()

            gate()
            lease = self._issuer.issue(expected, deadline=logical_deadline)
            gate()
            authority = lease.host
            default = 443 if lease.scheme == "https" else 80
            base = f"{lease.scheme}://{authority}"
            if lease.port != default:
                base += f":{lease.port}"

            def pinned(value):
                if value != lease.pinned_address:
                    raise CredentialLeaseError()

            payloads = []
            for suffix in ("status", "qemu", "lxc", "storage", "tasks"):
                gate()
                remaining = logical_deadline - self._monotonic()
                if remaining <= 0:
                    raise CredentialLeaseError()
                with ServiceTransport(
                    base, timeout=min(5.0, remaining),
                    max_bytes=MAX_RESPONSE_BYTES, resolver=self._resolver,
                    connector=self._connector, address_guard=pinned,
                ) as transport:
                    response = transport.request(
                        "GET", f"/api2/json/nodes/{lease.node}/{suffix}",
                        headers={
                            "Authorization": lease.authorization(),
                            "Accept": "application/json",
                        }, before_send=gate,
                    )
                gate()
                if response.status != 200:
                    raise ProbeTransportError("request_failed")
                types = [
                    value.split(";", 1)[0].strip().lower()
                    for key, value in response.headers if key == "content-type"
                ]
                if types != ["application/json"]:
                    raise TelemetrySchemaError()
                try:
                    value = json.loads(
                        response.body.decode("utf-8"), object_pairs_hook=_pairs,
                        parse_constant=lambda _value: (_ for _ in ()).throw(
                            TelemetrySchemaError()
                        ),
                    )
                except TelemetrySchemaError:
                    raise
                except (ValueError, TypeError, UnicodeError, RecursionError):
                    raise TelemetrySchemaError() from None
                payloads.append(_object(value, {"data"})["data"])
            node = _node(payloads[0], expected.node_revision)
            guests = (
                _guests(payloads[1], "qemu", expected.guest_revisions)
                + _guests(payloads[2], "lxc", expected.guest_revisions)
            )
            snapshot = ProxmoxTelemetrySnapshot(
                "live", expected.resource_revision, expected.binding_revision,
                expected.service_revision, now, now, node, guests,
                _storages(payloads[3]), _tasks(payloads[4]),
            )
            self._cache = snapshot
            self._cache_expectation = expected
            return snapshot
        except TelemetrySchemaError:
            return self._empty("schema_drift", expected, now)
        except CredentialLeaseError as error:
            if error.code == "binding_changed":
                return self._empty("schema_drift", expected, now)
            return self._unavailable(expected, now)
        except (ProbeTransportError, OSError, ValueError, TypeError, KeyError,
                UnicodeError, RecursionError):
            return self._unavailable(expected, now)
        except BaseException as error:
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            return self._unavailable(expected, now)
        finally:
            if lease is not None:
                lease.close()
            self._poll_lock.release()
