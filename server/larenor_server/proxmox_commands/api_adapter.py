"""Sealed, single-dispatch Proxmox API adapter for the private worker.

The adapter owns one exact service/guest binding.  It has no URL, header,
proxy, redirect, retry, node or guest selection input at execution time.
"""

from collections import deque
from dataclasses import asdict, dataclass
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import secrets
import stat
import threading
import time

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..files import private_read
from ..plugins.worker import DockerWorkerError, _safe_path
from ..services.transport import ProbeTransportError, ServiceTransport
from .worker_ipc import (
    EFFECT_ACTIONS, PackagedProxmoxApiResult, PackagedProxmoxCommand,
)


CREDENTIAL_MAGIC = b"LARENOR-PROXMOX-CREDENTIAL-V1\x00"
MAX_ENVELOPE_BYTES = 65_536
MAX_RESULT_BYTES = 8_192
_AAD = b"larenor:proxmox-api-binding:schema=1"
_ID = re.compile(r"[0-9a-f]{32}\Z")
_OPAQUE = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
_HOST = re.compile(
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
    r"(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\Z"
)
_NODE = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?\Z")
_TOKEN_ID = re.compile(r"[A-Za-z0-9._-]{1,64}@[A-Za-z0-9._-]{1,32}![A-Za-z0-9._-]{1,64}\Z")
_SOURCE = {
    "start": frozenset({"stopped"}),
    "shutdown": frozenset({"running"}),
    "stop": frozenset({"running"}),
    "reboot": frozenset({"running"}),
    "reset": frozenset({"running"}),
}
_TARGET = {
    "start": "running",
    "shutdown": "stopped",
    "stop": "stopped",
    "reboot": "running",
    "reset": "running",
}


class ProxmoxApiAdapterError(Exception):
    def __init__(self, code="adapter_unavailable"):
        self.code = code if code in {
            "adapter_unavailable", "binding_unavailable", "binding_changed",
            "request_replayed",
        } else "adapter_unavailable"
        super().__init__(self.code)


def _revision(value):
    return type(value) is int and 1 <= value <= 2**63 - 1


def _private_address(value):
    try:
        address = ipaddress.ip_address(value)
        if (
            address.is_unspecified or address.is_multicast or address.is_link_local
            or address.is_reserved
        ):
            raise ValueError()
        if address.is_loopback:
            return address.compressed
        if address.version == 4 and any(address in network for network in (
            ipaddress.ip_network("10.0.0.0/8"),
            ipaddress.ip_network("172.16.0.0/12"),
            ipaddress.ip_network("192.168.0.0/16"),
        )):
            return address.compressed
        if address.version == 6 and address in ipaddress.ip_network("fc00::/7"):
            return address.compressed
    except (ValueError, TypeError):
        pass
    raise ProxmoxApiAdapterError("binding_unavailable")


@dataclass(frozen=True, repr=False)
class ProxmoxServiceBinding:
    schema_version: int
    resource_id: str
    resource_revision: int
    binding_id: str
    binding_revision: int
    service_id: str
    service_revision: int
    scheme: str
    host: str
    port: int
    pinned_address: str
    node: str
    guest_kind: str
    guest_id: int
    token_id: str
    token_secret: str

    def __post_init__(self):
        try:
            canonical_address = _private_address(self.pinned_address)
            if (
                type(self.schema_version) is not int or self.schema_version != 1
                or type(self.resource_id) is not str or _ID.fullmatch(self.resource_id) is None
                or not _revision(self.resource_revision)
                or any(type(value) is not str or _OPAQUE.fullmatch(value) is None
                       for value in (self.binding_id, self.service_id))
                or not _revision(self.binding_revision)
                or not _revision(self.service_revision)
                or self.scheme not in {"http", "https"}
                or type(self.host) is not str or len(self.host) > 253
                or _HOST.fullmatch(self.host) is None
                or self.host.lower() != self.host
                or type(self.port) is not int or not 1 <= self.port <= 65535
                or self.pinned_address != canonical_address
                or self.scheme == "http" and not ipaddress.ip_address(canonical_address).is_loopback
                or type(self.node) is not str or _NODE.fullmatch(self.node) is None
                or self.guest_kind not in {"qemu", "lxc"}
                or type(self.guest_id) is not int or not 1 <= self.guest_id <= 999_999_999
                or type(self.token_id) is not str or _TOKEN_ID.fullmatch(self.token_id) is None
                or type(self.token_secret) is not str
                or not 1 <= len(self.token_secret.encode("utf-8")) <= 2048
                or any(ord(char) < 33 or ord(char) == 127 for char in self.token_secret)
            ):
                raise ValueError()
        except ProxmoxApiAdapterError:
            raise
        except (ValueError, TypeError, UnicodeError):
            raise ProxmoxApiAdapterError("binding_unavailable") from None

    def __repr__(self):
        return (
            "ProxmoxServiceBinding(resource_id=%r, resource_revision=%r, binding_id=%r, "
            "binding_revision=%r, service_id=%r, service_revision=%r, "
            "endpoint=<redacted>, guest=<redacted>, credential=<redacted>)"
            % (
                self.resource_id, self.resource_revision,
                self.binding_id, self.binding_revision,
                self.service_id, self.service_revision,
            )
        )


def _private_file(path):
    try:
        return _safe_path(
            Path(path), uid=os.geteuid(), kind=stat.S_ISREG, private=True
        )
    except (OSError, ValueError, TypeError, DockerWorkerError):
        raise ProxmoxApiAdapterError("binding_unavailable") from None


def _key(path):
    try:
        value = private_read(_private_file(path), 32)
        if type(value) is not bytes or len(value) != 32:
            raise ValueError()
        return value
    except ProxmoxApiAdapterError:
        raise
    except Exception:
        raise ProxmoxApiAdapterError("binding_unavailable") from None


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError()
        result[key] = value
    return result


def _decode(value):
    try:
        raw = json.loads(
            value.decode("utf-8"), object_pairs_hook=_pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
        keys = {
            "schema_version", "resource_id", "resource_revision",
            "binding_id", "binding_revision",
            "service_id", "service_revision", "scheme", "host", "port",
            "pinned_address", "node", "guest_kind", "guest_id", "token_id",
            "token_secret",
        }
        if type(raw) is not dict or set(raw) != keys:
            raise ValueError()
        return ProxmoxServiceBinding(**raw)
    except ProxmoxApiAdapterError:
        raise
    except (ValueError, TypeError, UnicodeError, RecursionError):
        raise ProxmoxApiAdapterError("binding_unavailable") from None


def _atomic_write(path, raw):
    target = Path(path)
    temporary = None
    descriptor = None
    try:
        _safe_path(target.parent, uid=os.geteuid(), kind=stat.S_ISDIR, private=True)
        if target.exists() or target.is_symlink():
            _private_file(target)
        temporary = target.parent / (target.name + "." + secrets.token_hex(16) + ".tmp")
        descriptor = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
        )
        written = 0
        while written < len(raw):
            count = os.write(descriptor, raw[written:])
            if count <= 0:
                raise OSError()
            written += count
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        _private_file(temporary)
        os.replace(temporary, target)
        temporary = None
        _private_file(target)
        directory = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except BaseException as error:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        raise ProxmoxApiAdapterError("binding_unavailable") from None


def seal_service_binding(path, key_path, binding):
    if not isinstance(binding, ProxmoxServiceBinding):
        raise ProxmoxApiAdapterError("binding_unavailable")
    try:
        plain = json.dumps(
            asdict(binding), sort_keys=True, separators=(",", ":"),
            ensure_ascii=True, allow_nan=False,
        ).encode("ascii")
        nonce = secrets.token_bytes(12)
        raw = CREDENTIAL_MAGIC + nonce + AESGCM(_key(key_path)).encrypt(
            nonce, plain, _AAD
        )
        if len(raw) > MAX_ENVELOPE_BYTES:
            raise ValueError()
        _atomic_write(path, raw)
    except ProxmoxApiAdapterError:
        raise
    except Exception:
        raise ProxmoxApiAdapterError("binding_unavailable") from None


def load_service_binding(path, key_path):
    try:
        raw = private_read(_private_file(path), MAX_ENVELOPE_BYTES)
        if (
            not raw.startswith(CREDENTIAL_MAGIC)
            or len(raw) < len(CREDENTIAL_MAGIC) + 12 + 16
        ):
            raise ValueError()
        start = len(CREDENTIAL_MAGIC)
        nonce = raw[start:start + 12]
        plain = AESGCM(_key(key_path)).decrypt(nonce, raw[start + 12:], _AAD)
        return _decode(plain)
    except ProxmoxApiAdapterError:
        raise
    except (InvalidTag, ValueError, TypeError, OSError):
        raise ProxmoxApiAdapterError("binding_unavailable") from None


class ProxmoxApiEffectAdapter:
    def __init__(
        self, binding, *, resolver=None, connector=None, confirm_readback=False,
    ):
        if (
            not isinstance(binding, ProxmoxServiceBinding)
            or resolver is not None and not callable(resolver)
            or connector is not None and not callable(connector)
            or type(confirm_readback) is not bool
        ):
            raise ProxmoxApiAdapterError("binding_unavailable")
        self._binding = binding
        self._resolver = resolver
        self._connector = connector
        self._confirm_readback = confirm_readback
        self._lock = threading.Lock()
        self._seen = set()
        self._order = deque()

    @classmethod
    def from_sealed(cls, path, key_path, **transport_seams):
        return cls(load_service_binding(path, key_path), **transport_seams)

    def __repr__(self):
        return "ProxmoxApiEffectAdapter(<private>)"

    def _remember(self, request_id):
        with self._lock:
            if request_id in self._seen:
                raise ProxmoxApiAdapterError("request_replayed")
            self._seen.add(request_id)
            self._order.append(request_id)
            while len(self._order) > 256:
                self._seen.discard(self._order.popleft())

    def _matches(self, command):
        selected = self._binding
        return (
            command.resource_id == selected.resource_id
            and command.resource_revision == selected.resource_revision
            and command.binding_id == selected.binding_id
            and command.binding_revision == selected.binding_revision
            and command.service_id == selected.service_id
            and command.service_revision == selected.service_revision
            and command.guest_kind == selected.guest_kind
            and selected.pinned_address in command.allowed_addresses
        )

    def _unknown(self, command, upid=None):
        return PackagedProxmoxApiResult(
            "unknown", command.current_state, command.status_revision, upid
        )

    @staticmethod
    def _json(response):
        types = [
            value.split(";", 1)[0].strip().lower()
            for key, value in response.headers if key == "content-type"
        ]
        if types != ["application/json"]:
            raise ValueError()
        return json.loads(
            response.body.decode("utf-8"), object_pairs_hook=_pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )

    def execute(self, command, *, deadline, cancelled):
        if (
            not isinstance(command, PackagedProxmoxCommand)
            or command.action not in EFFECT_ACTIONS
            or command.current_state not in _SOURCE.get(command.action, ())
            or not callable(cancelled)
            or type(deadline) not in (int, float) or isinstance(deadline, bool)
            or not math.isfinite(deadline)
        ):
            raise ProxmoxApiAdapterError("binding_changed")
        if not self._matches(command):
            raise ProxmoxApiAdapterError("binding_changed")
        self._remember(command.request_id)

        def gate():
            try:
                if time.monotonic() >= deadline or cancelled():
                    raise ProxmoxApiAdapterError()
            except ProxmoxApiAdapterError:
                raise
            except BaseException as error:
                if isinstance(error, (KeyboardInterrupt, SystemExit)):
                    raise
                raise ProxmoxApiAdapterError() from None

        selected = self._binding

        def pinned(value):
            if value != selected.pinned_address:
                raise ProxmoxApiAdapterError()

        try:
            gate()
            timeout = min(5.0, deadline - time.monotonic())
            if timeout <= 0:
                return self._unknown(command)
            authority = selected.host
            default = 443 if selected.scheme == "https" else 80
            base = f"{selected.scheme}://{authority}"
            if selected.port != default:
                base += f":{selected.port}"
            mutation_path = (
                f"/api2/json/nodes/{selected.node}/{selected.guest_kind}/"
                f"{selected.guest_id}/status/{command.action}"
            )
            with ServiceTransport(
                base, timeout=timeout, max_bytes=MAX_RESULT_BYTES,
                resolver=self._resolver, connector=self._connector,
                address_guard=pinned,
            ) as transport:
                response = transport.request(
                    "POST", mutation_path,
                    headers={
                        "Authorization": (
                            "PVEAPIToken=" + selected.token_id + "="
                            + selected.token_secret
                        ),
                        "Accept": "application/json",
                        "Content-Type": "application/x-www-form-urlencoded",
                    },
                    body=b"", before_send=gate,
                )
            gate()
        except (ProbeTransportError, ProxmoxApiAdapterError):
            return self._unknown(command)
        except BaseException as error:
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            return self._unknown(command)
        if response.status in {400, 401, 403, 404, 405}:
            return PackagedProxmoxApiResult(
                "failed", command.current_state, command.status_revision
            )
        if response.status != 200:
            return self._unknown(command)
        try:
            value = self._json(response)
            upid = value["data"]
            if (
                type(value) is not dict or set(value) != {"data"}
                or type(upid) is not str
                or not 1 <= len(upid.encode("utf-8")) <= 512
                or not upid.startswith("UPID:")
                or any(ord(char) < 33 or ord(char) == 127 for char in upid)
            ):
                raise ValueError()
        except (ValueError, TypeError, KeyError, UnicodeError, RecursionError):
            return self._unknown(command)
        if not self._confirm_readback:
            return self._unknown(command, upid)

        try:
            gate()
            timeout = min(5.0, deadline - time.monotonic())
            if timeout <= 0:
                return self._unknown(command, upid)
            readback_path = (
                f"/api2/json/nodes/{selected.node}/{selected.guest_kind}/"
                f"{selected.guest_id}/status/current"
            )
            with ServiceTransport(
                base, timeout=timeout, max_bytes=MAX_RESULT_BYTES,
                resolver=self._resolver, connector=self._connector,
                address_guard=pinned,
            ) as transport:
                readback = transport.request(
                    "GET", readback_path,
                    headers={
                        "Authorization": (
                            "PVEAPIToken=" + selected.token_id + "="
                            + selected.token_secret
                        ),
                        "Accept": "application/json",
                    },
                    before_send=gate,
                )
            gate()
            if readback.status != 200:
                return self._unknown(command, upid)
            value = self._json(readback)
            if (
                type(value) is not dict or set(value) != {"data"}
                or type(value["data"]) is not dict
                or set(value["data"]) != {"status"}
                or value["data"]["status"] not in {"running", "stopped"}
            ):
                raise ValueError()
            state = value["data"]["status"]
            if state != _TARGET[command.action]:
                return self._unknown(command, upid)
            return PackagedProxmoxApiResult(
                "succeeded", state, command.status_revision + 1, upid,
            )
        except (ProbeTransportError, ProxmoxApiAdapterError, ValueError,
                TypeError, KeyError, UnicodeError, RecursionError):
            return self._unknown(command, upid)
        except BaseException as error:
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            return self._unknown(command, upid)
