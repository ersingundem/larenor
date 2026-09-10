"""Bounded, authenticated, read-only Keenetic NDM telemetry transport.

Only the fixed NDM ``show`` command tree is reachable from this module. The
transport never follows redirects, retries a changed address, or exposes a
cookie, challenge digest, credential, upstream body, or URL in an error.
"""

from collections import OrderedDict
from collections.abc import Mapping
from dataclasses import dataclass
import hashlib
import ipaddress
import json
import math
import re
import socket
import threading
import time

from pydantic import ValidationError

from ..errors import ApiError
from ..services.network_probes import _cookie_if_present, _keenetic_cookie_name, _one_header
from ..services.probe import _ProbeStop
from ..services.transport import ProbeResponse, ProbeTransportError, ServiceTransport
from .models import Telemetry


_MAX_REPLY = 256 * 1024
_TOTAL_TIMEOUT = 9.0
_MAX_SAMPLES = 128
_MAX_SAMPLE_AGE = 20.0
_SAFE = re.compile(r"[ -~]{1,128}\Z")
_VERSION = re.compile(r"[2-5]\.[A-Za-z0-9][A-Za-z0-9._+\-]{0,78}\Z")
_MAC = re.compile(r"[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}\Z")
_READ_COMMANDS = (
    {"version": {}}, {"system": {}}, {"interface": {}},
    {"internet": {"status": {}}}, {"ip": {"hotspot": {}}},
)


@dataclass(frozen=True)
class FirmwareCapabilities:
    family: str
    commands: tuple[str, ...]


_COMMAND_NAMES = ("version", "system", "interface", "internet.status", "ip.hotspot", "interface.stat")
_FIRMWARE = {
    2: FirmwareCapabilities("ndms-2", _COMMAND_NAMES),
    3: FirmwareCapabilities("keeneticos-3", _COMMAND_NAMES),
    4: FirmwareCapabilities("keeneticos-4", _COMMAND_NAMES),
    5: FirmwareCapabilities("keeneticos-5", _COMMAND_NAMES),
}


def _unsupported():
    raise ApiError("keenetic_upstream_unsupported", 502)


def firmware_capabilities(value):
    if not isinstance(value, str) or _VERSION.fullmatch(value) is None:
        _unsupported()
    return _FIRMWARE[int(value[0])]


def _lan_literal(value):
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        raise ProbeTransportError("invalid_resolution") from None
    if str(ip) != value or "%" in value or getattr(ip, "ipv4_mapped", None) is not None:
        raise ProbeTransportError("invalid_resolution")
    lan = (ip.version == 4 and any(ip in ipaddress.ip_network(item) for item in (
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")) or
        ip.version == 6 and ip in ipaddress.ip_network("fc00::/7"))
    if not lan or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_unspecified:
        raise ProbeTransportError("address_blocked")
    return str(ip)


class _PinnedLanResolver:
    """Resolve every request and reject any change from the first exact LAN set."""

    def __init__(self, resolver=socket.getaddrinfo):
        self._resolver = resolver
        self._authority = None
        self._addresses = None
        self._lock = threading.Lock()

    @staticmethod
    def _normalize(answers, port):
        if not isinstance(answers, (list, tuple)) or not 1 <= len(answers) <= 8:
            raise ProbeTransportError("invalid_resolution")
        normalized = []
        try:
            for answer in answers:
                family, kind, protocol, _name, address = answer
                if (family not in {socket.AF_INET, socket.AF_INET6} or kind != socket.SOCK_STREAM
                        or protocol not in {0, socket.IPPROTO_TCP} or address[1] != port
                        or len(address) != (2 if family == socket.AF_INET else 4)
                        or family == socket.AF_INET6 and address[2:] != (0, 0)):
                    raise ValueError
                literal = _lan_literal(address[0])
                sockaddr = (literal, port) if family == socket.AF_INET else (literal, port, 0, 0)
                normalized.append((family, socket.SOCK_STREAM, protocol, "", sockaddr))
        except (TypeError, ValueError, IndexError):
            raise ProbeTransportError("invalid_resolution") from None
        identities = {(item[0], item[4]) for item in normalized}
        if len(identities) != len(normalized):
            raise ProbeTransportError("invalid_resolution")
        return tuple(normalized), frozenset(identities)

    def __call__(self, host, port):
        try:
            answers = self._resolver(host, port)
        except ProbeTransportError:
            raise
        except Exception:
            raise ProbeTransportError("resolution_failed") from None
        normalized, identities = self._normalize(answers, port)
        with self._lock:
            authority = (host, port)
            if self._authority is None:
                self._authority, self._addresses = authority, identities
            elif self._authority != authority or self._addresses != identities:
                raise ProbeTransportError("address_blocked")
        return normalized


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate")
        result[key] = value
    return result


def _invalid_number(_value):
    raise ValueError("non_finite")


def _finite_float(value):
    result = float(value)
    if not math.isfinite(result):
        raise ValueError("non_finite")
    return result


def _bounded_shape(value):
    remaining = 4096

    def visit(item, depth):
        nonlocal remaining
        remaining -= 1
        if remaining < 0 or depth > 12:
            raise ValueError("shape")
        if isinstance(item, dict):
            if len(item) > 1024:
                raise ValueError("shape")
            for key, child in item.items():
                if not isinstance(key, str) or not 1 <= len(key) <= 128 or _SAFE.fullmatch(key) is None:
                    raise ValueError("shape")
                visit(child, depth + 1)
        elif isinstance(item, list):
            if len(item) > 1024:
                raise ValueError("shape")
            for child in item:
                visit(child, depth + 1)
        elif isinstance(item, str):
            if len(item) > 2048 or any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in item):
                raise ValueError("shape")
        elif item is not None and type(item) not in {bool, int, float}:
            raise ValueError("shape")

    visit(value, 0)
    return value


def _json_response(response):
    if not isinstance(response, ProbeResponse) or type(response.status) is not int:
        _unsupported()
    content_types = [value for name, value in response.headers if name.lower() == "content-type"]
    if len(content_types) > 1 or content_types and content_types[0].split(";", 1)[0].strip().lower() != "application/json":
        _unsupported()
    if not isinstance(response.body, bytes) or len(response.body) > _MAX_REPLY:
        _unsupported()
    try:
        value = json.loads(response.body.decode("utf-8"), object_pairs_hook=_unique_object,
                           parse_constant=_invalid_number, parse_float=_finite_float)
        return _bounded_shape(value)
    except (ValueError, TypeError, UnicodeError, json.JSONDecodeError):
        _unsupported()


def _object(value):
    if type(value) is not dict:
        _unsupported()
    return value


def _text(value, *, length=128):
    if not isinstance(value, str) or not 1 <= len(value) <= length or _SAFE.fullmatch(value) is None:
        _unsupported()
    return value


def _integer(value):
    if isinstance(value, str) and re.fullmatch(r"[0-9]{1,19}", value):
        value = int(value)
    if type(value) is not int or not 0 <= value <= 2**63 - 1:
        _unsupported()
    return value


def _percent(value):
    if type(value) not in {int, float} or not math.isfinite(value) or not 0 <= value <= 100:
        _unsupported()
    return float(value)


def _flag(value):
    if type(value) is bool:
        return value
    if value in {"yes", "up", "connected", "on"}:
        return True
    if value in {"no", "down", "disconnected", "off"}:
        return False
    _unsupported()


def _internet_access(value):
    if value in {"permit", "allow", "allowed"}:
        return "allowed"
    if value in {"deny", "block", "blocked"}:
        return "paused"
    _unsupported()


def _revision(value):
    """Closed projections use a stable positive revision fingerprint."""
    try:
        encoded = json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
        ).encode("ascii")
    except (TypeError, ValueError, UnicodeError):
        _unsupported()
    result = int.from_bytes(hashlib.blake2b(encoded, digest_size=8).digest(), "big")
    return (result & (2**63 - 1)) or 1


def _ip(value):
    value = _text(value, length=64)
    try:
        parsed = ipaddress.ip_address(value)
    except ValueError:
        _unsupported()
    if str(parsed) != value or "%" in value or getattr(parsed, "ipv4_mapped", None) is not None:
        _unsupported()
    return value, parsed


def _status(response, *, challenge=False):
    if response.status == 200 or challenge and response.status == 401:
        return response
    if response.status == 401:
        raise ApiError("keenetic_upstream_unauthorized", 502)
    if response.status == 403:
        raise ApiError("keenetic_upstream_denied", 502)
    if response.status == 429 or 500 <= response.status <= 599:
        raise ApiError("keenetic_upstream_unavailable", 502)
    _unsupported()


@dataclass(frozen=True)
class _Sample:
    at: float
    uptime: int
    rx: int
    tx: int
    router_timestamp: float | int | None


class KeeneticReadOnlyTransport:
    def __init__(self, *, factory=ServiceTransport, resolver=socket.getaddrinfo, clock=time.monotonic):
        self._factory, self._system_resolver, self._clock = factory, resolver, clock
        self._samples = OrderedDict()
        self._lock = threading.Lock()
        self._active = set()
        self._closed = False

    def close(self):
        with self._lock:
            self._closed = True
            active = tuple(self._active)
            self._samples.clear()
        for transport in active:
            transport.close()

    def _request(self, connection, resolver, deadline, guard, method, path, headers=None, body=None, *, challenge=False):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ApiError("request_timeout", 408)
        transport = None
        try:
            with self._lock:
                if self._closed:
                    raise ApiError("keenetic_upstream_unavailable", 502)
            transport = self._factory(connection.base_url, timeout=min(4.0, remaining), max_bytes=_MAX_REPLY,
                                      resolver=resolver, address_guard=_lan_literal)
            with self._lock:
                if self._closed:
                    transport.close()
                    raise ApiError("keenetic_upstream_unavailable", 502)
                self._active.add(transport)
            response = transport.request(method, path, headers=headers, body=body, before_send=guard)
            guard()
            if not isinstance(response, ProbeResponse) or not isinstance(response.body, bytes) or len(response.body) > _MAX_REPLY:
                _unsupported()
            return _status(response, challenge=challenge)
        except ApiError:
            raise
        except ProbeTransportError as error:
            if error.code == "request_timeout":
                raise ApiError("request_timeout", 408) from None
            if error.code == "address_blocked":
                raise ApiError("keenetic_upstream_denied", 502) from None
            if error.code in {"invalid_response", "response_too_large", "unsupported_encoding", "invalid_resolution"}:
                _unsupported()
            raise ApiError("keenetic_upstream_unavailable", 502) from None
        except Exception:
            raise ApiError("keenetic_upstream_unavailable", 502) from None
        finally:
            if transport is not None:
                transport.close()
                with self._lock:
                    self._active.discard(transport)

    def _authenticate(self, connection, resolver, deadline, guard):
        credentials = connection.credentials
        if (not isinstance(credentials, Mapping) or set(credentials) != {"username", "password"}
                or any(not isinstance(item, str) or not 1 <= len(item) <= 2048 or
                       any(ord(char) < 32 or ord(char) == 127 for char in item)
                       for item in credentials.values())):
            _unsupported()
        response = self._request(connection, resolver, deadline, guard, "GET", "/auth", challenge=True)
        if response.status != 401:
            raise ApiError("keenetic_upstream_unauthorized", 502)
        try:
            realm = _one_header(response, "x-ndm-realm")
            challenge = _one_header(response, "x-ndm-challenge")
            name, session_id = _keenetic_cookie_name(response, realm, challenge)
            login_url = connection.base_url.rstrip("/") + "/auth"
            cookie = _cookie_if_present(response, login_url, name)
            if cookie is not None and session_id is not None and session_id != cookie.value:
                raise _ProbeStop()
            hashed = hashlib.md5(
                f'{credentials["username"]}:{realm}:{credentials["password"]}'.encode("utf-8"),
                usedforsecurity=False,
            ).hexdigest()
            digest = hashlib.sha256((challenge + hashed).encode("utf-8")).hexdigest()
            headers = {"Content-Type": "application/json"}
            if cookie is not None:
                headers["Cookie"] = cookie.header(login_url)
            body = json.dumps({"login": credentials["username"], "password": digest}, separators=(",", ":")).encode()
            response = self._request(connection, resolver, deadline, guard, "POST", "/auth", headers, body)
            replacement = _cookie_if_present(response, login_url, name)
            cookie = replacement if replacement is not None else cookie
            if cookie is None:
                raise _ProbeStop()
            return {"Cookie": cookie.header(connection.base_url.rstrip("/") + "/rci/show")}
        except _ProbeStop:
            _unsupported()

    @staticmethod
    def _interfaces(value, gateway):
        rows = []
        if type(value) is dict:
            rows = [(key, _object(item)) for key, item in value.items()]
        elif type(value) is list:
            for item in value:
                item = _object(item)
                rows.append((_text(item.get("id")), item))
        else:
            _unsupported()
        if not 1 <= len(rows) <= 64 or len({key for key, _ in rows}) != len(rows):
            _unsupported()
        result = []
        for identity, item in rows:
            identity = _text(identity)
            if item.get("id") is not None and item["id"] != identity:
                _unsupported()
            type_name = _text(item.get("type", "other"))
            signal = item.get("connected", item.get("link", item.get("state")))
            online = _flag(signal)
            address = item.get("address")
            if address is not None:
                address = _ip(address)[0]
            kind = ("wan" if identity == gateway else "wifi" if "accesspoint" in type_name.casefold()
                    else "lan" if "bridge" in type_name.casefold() else "vpn" if "vpn" in type_name.casefold()
                    else "other")
            guest = item.get("guest")
            if guest is not None:
                guest = _flag(guest)
                if guest and kind != "wifi":
                    _unsupported()
            projected = {"id": identity, "name": _text(item.get("description", identity)), "kind": kind,
                         "online": online, "address": address}
            if guest is not None:
                projected["guest"] = guest
            result.append(projected)
        if gateway not in {item["id"] for item in result}:
            _unsupported()
        return result

    @staticmethod
    def _statistics(value, interfaces):
        value = _object(value)
        rows = value.get("interface")
        if type(rows) is not list or len(rows) != len(interfaces):
            _unsupported()
        result = []
        for expected, raw in zip(interfaces, rows, strict=True):
            raw = _object(raw)
            identity = raw.get("name", raw.get("id"))
            if identity != expected["id"]:
                _unsupported()
            stat = _object(raw.get("stat"))
            timestamp = stat.get("timestamp")
            if timestamp is not None and (type(timestamp) not in {int, float} or not math.isfinite(timestamp)):
                _unsupported()
            result.append({**expected, "rxBytes": _integer(stat.get("rxbytes")),
                           "txBytes": _integer(stat.get("txbytes")), "timestamp": timestamp})
        return result

    @staticmethod
    def _hosts(value, interface_ids):
        hotspot = _object(value)
        rows = hotspot.get("host")
        if type(rows) is not list or len(rows) > 512:
            _unsupported()
        result = []
        for raw in rows:
            raw = _object(raw)
            mac = raw.get("mac")
            if not isinstance(mac, str) or _MAC.fullmatch(mac) is None:
                _unsupported()
            mac = mac.upper()
            via = _text(raw.get("via"))
            if via not in interface_ids:
                _unsupported()
            ip_value = _ip(raw.get("ip"))[0]
            projected = {"id": mac, "name": _text(raw.get("name", mac)), "ipAddress": ip_value,
                         "macAddress": mac, "interfaceId": via, "online": _flag(raw.get("active")),
                         "registered": _flag(raw.get("registered"))}
            if "access" in raw:
                projected["internetAccess"] = _internet_access(raw["access"])
            result.append(projected)
        if len({item["id"] for item in result}) != len(result):
            _unsupported()
        return result

    def _rate(self, connection, interface, uptime):
        now = self._clock()
        if type(now) not in {int, float} or not math.isfinite(now):
            raise ApiError("keenetic_upstream_unavailable", 502)
        key = (connection.id, connection.revision, interface["id"])
        current = _Sample(float(now), uptime, interface["rxBytes"], interface["txBytes"], interface["timestamp"])
        with self._lock:
            previous = self._samples.pop(key, None)
            self._samples[key] = current
            while len(self._samples) > _MAX_SAMPLES:
                self._samples.popitem(last=False)
        if previous is None:
            return None, None
        elapsed = current.at - previous.at
        if (not 0 < elapsed <= _MAX_SAMPLE_AGE or current.uptime < previous.uptime
                or current.rx < previous.rx or current.tx < previous.tx):
            _unsupported()
        if (current.router_timestamp is not None and previous.router_timestamp is not None
                and current.router_timestamp <= previous.router_timestamp):
            _unsupported()
        return int((current.rx - previous.rx) / elapsed), int((current.tx - previous.tx) / elapsed)

    def read(self, connection, guard):
        if (connection.kind != "keenetic" or not callable(guard) or type(connection.revision) is not int
                or not isinstance(connection.id, str)):
            _unsupported()
        guard()
        resolver = _PinnedLanResolver(self._system_resolver)
        deadline = time.monotonic() + _TOTAL_TIMEOUT
        headers = self._authenticate(connection, resolver, deadline, guard)
        batch_body = json.dumps(list(_READ_COMMANDS), separators=(",", ":")).encode()
        batch_response = self._request(connection, resolver, deadline, guard, "POST", "/rci/show",
                                       {**headers, "Content-Type": "application/json"}, batch_body)
        batch = _json_response(batch_response)
        if type(batch) is not list or len(batch) != len(_READ_COMMANDS):
            _unsupported()
        values = []
        for envelope, command in zip(batch, _READ_COMMANDS, strict=True):
            envelope = _object(envelope)
            key = next(iter(command))
            if set(envelope) != {key}:
                _unsupported()
            values.append(envelope[key])
        version, system, interface_value, internet_value, hosts_value = values
        version = _object(version)
        release = version.get("release") or version.get("title")
        if version.get("release") is not None and version.get("title") is not None and version["release"] != version["title"]:
            _unsupported()
        firmware_capabilities(release)
        _text(version.get("model"))
        if not (isinstance(version.get("hw_id"), str) and re.fullmatch(r"KN-[0-9]{4}", version["hw_id"])
                or version.get("manufacturer") == "Keenetic Ltd."):
            _unsupported()
        firmware_revision = _revision({
            "release": release,
            "model": version.get("model"),
            "hardware": version.get("hw_id"),
            "manufacturer": version.get("manufacturer"),
        })
        system = _object(system)
        uptime = _integer(system.get("uptime"))
        cpu = _percent(system.get("cpuload"))
        memory = system.get("memory")
        if not isinstance(memory, str) or re.fullmatch(r"[0-9]{1,19}/[0-9]{1,19}", memory) is None:
            _unsupported()
        used, total = map(int, memory.split("/"))
        if total <= 0 or used > total:
            _unsupported()
        memory_percent = used * 100.0 / total
        internet = _object(internet_value)
        status = _object(internet.get("status"))
        online = _flag(status.get("internet"))
        gateway = _object(status.get("gateway"))
        gateway_id = _text(gateway.get("interface"))
        _ip(gateway.get("address"))
        interfaces = self._interfaces(interface_value, gateway_id)
        stat_body = json.dumps({"interface": [{"name": item["id"], "stat": {}} for item in interfaces]},
                               separators=(",", ":")).encode()
        stat_response = self._request(connection, resolver, deadline, guard, "POST", "/rci/show",
                                      {**headers, "Content-Type": "application/json"}, stat_body)
        interfaces = self._statistics(_json_response(stat_response), interfaces)
        wan = next(item for item in interfaces if item["id"] == gateway_id)
        download, upload = self._rate(connection, wan, uptime)
        public_ip = None
        if wan["address"] is not None:
            parsed = ipaddress.ip_address(wan["address"])
            if parsed.is_global:
                public_ip = wan["address"]
        hosts = self._hosts(_object(_object(hosts_value).get("hotspot")), {item["id"] for item in interfaces})
        status_revision = _revision({
            "firmwareRevision": firmware_revision,
            "internet": online,
            "wan": sorted(
                (item["id"], item["online"])
                for item in interfaces
                if item["kind"] == "wan"
            ),
            "guest": sorted(
                (item["id"], item["online"])
                for item in interfaces
                if item.get("guest") is True
            ),
            "clients": sorted(
                (item["macAddress"], item["internetAccess"])
                for item in hosts
                if "internetAccess" in item
            ),
        })
        for item in interfaces:
            item.pop("timestamp")
        try:
            return Telemetry.model_validate({
                "status": {"online": online, "publicIp": public_ip, "uptimeSeconds": uptime,
                           "firmware": release, "cpuPercent": cpu, "memoryPercent": memory_percent,
                           "firmwareRevision": firmware_revision,
                           "statusRevision": status_revision},
                "interfaces": interfaces,
                "traffic": {"rxBytes": wan["rxBytes"], "txBytes": wan["txBytes"],
                            "downloadBps": download, "uploadBps": upload},
                "hosts": hosts,
            })
        except ValidationError:
            _unsupported()


def read_telemetry(connection, guard):
    """Compatibility seam for callers without an adapter-owned lifecycle."""
    reader = KeeneticReadOnlyTransport()
    try:
        return reader.read(connection, guard)
    finally:
        reader.close()
