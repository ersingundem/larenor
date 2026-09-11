"""Service-bound Keenetic RCI transport with a closed mutation surface.

The transport resolves its endpoint and credentials from the encrypted service
store immediately before dispatch. The command object contains only a packaged
operation and the already-authorized revision tuple. Production construction is
safe but remains opt-in: no Core or worker startup path installs this transport.
"""

import base64
import hashlib
import ipaddress
import json
import math
import re
import secrets
import socket
import time
from urllib.parse import urlsplit

from pydantic import ValidationError

from ..errors import ApiError
from ..services.transport import ProbeTransportError, ServiceTransport
from ..services.service import ServiceConnection
from .credential_lease import KeeneticLeaseError
from .rci_adapter import RciCommand
from .service import KeeneticEffectError, RESULT


_PRIVATE_V4 = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)
_PRIVATE_V6 = ipaddress.ip_network("fc00::/7")
_WIFI = re.compile(r"WifiMaster[0-9]{1,3}/AccessPoint[0-9]{1,3}\Z")
_MAC = re.compile(r"(?:[0-9A-F]{2}:){5}[0-9A-F]{2}\Z")
_INTERFACE = re.compile(r"[A-Za-z][A-Za-z0-9._/-]{0,63}\Z")
_USERNAME = re.compile(r"[A-Za-z0-9_.@-]{1,80}\Z")
_AUTH_PARAMETER = re.compile(
    r'\s*([A-Za-z][A-Za-z0-9_-]*)\s*=\s*(?:"([^"\\]*)"|([A-Za-z0-9_-]+))\s*(?:,|\Z)'
)
_MAX_RESPONSE = 128 * 1024


def keenetic_lan_address(value, *, allow_loopback_fixture=False):
    """Reject everything outside explicit RFC1918/ULA ranges.

    Loopback is exposed solely as an explicit fixture seam. Link-local, CGNAT,
    multicast, documentation and public addresses never qualify as router LAN.
    """
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        raise ProbeTransportError("address_blocked") from None
    mapped = address.ipv4_mapped if isinstance(address, ipaddress.IPv6Address) else None
    check = mapped or address
    if allow_loopback_fixture and check.is_loopback:
        return None
    allowed = (
        check.version == 4 and any(check in network for network in _PRIVATE_V4)
    ) or check.version == 6 and check in _PRIVATE_V6
    if not allowed:
        raise ProbeTransportError("address_blocked")
    return None


class _PinnedResolver:
    def __init__(self, resolver):
        self._resolver = resolver
        self._key = None
        self._answers = None

    def __call__(self, host, port):
        key = (host, port)
        if self._key is None:
            answers = self._resolver(host, port)
            # Freeze the first answer set. The lower transport validates every
            # numeric address and the connected peer on each request.
            self._answers = tuple(tuple(item) for item in answers)
            self._key = key
        elif self._key != key:
            raise OSError("pinned_origin_changed")
        return self._answers


def _system_resolver(host, port):
    return socket.getaddrinfo(
        host, port, type=socket.SOCK_STREAM, proto=socket.IPPROTO_TCP
    )


def _one_header(response, name):
    values = [value for key, value in response.headers if key.lower() == name]
    if len(values) != 1:
        raise KeeneticEffectError("keenetic_effect_rejected")
    value = values[0]
    if (
        not isinstance(value, str)
        or not 1 <= len(value) <= 4096
        or any(not 32 <= ord(char) < 127 for char in value)
    ):
        raise KeeneticEffectError("keenetic_effect_rejected")
    return value


def _digest_parameters(value):
    fields = {}
    position = 0
    while position < len(value):
        match = _AUTH_PARAMETER.match(value, position)
        if match is None:
            raise KeeneticEffectError("keenetic_effect_rejected")
        key, quoted, token = match.groups()
        key = key.lower()
        if key in fields:
            raise KeeneticEffectError("keenetic_effect_rejected")
        fields[key] = quoted if quoted is not None else token
        position = match.end()
    allowed = {"realm", "nonce", "algorithm", "qop", "opaque"}
    if set(fields) - allowed or set(fields) < {"realm", "nonce"}:
        raise KeeneticEffectError("keenetic_effect_rejected")
    if fields["realm"] != "Keenetic" or not 1 <= len(fields["nonce"]) <= 256:
        raise KeeneticEffectError("keenetic_effect_rejected")
    algorithm = fields.get("algorithm", "MD5").upper()
    if algorithm not in {"MD5", "SHA-256"}:
        raise KeeneticEffectError("keenetic_effect_rejected")
    qop = fields.get("qop", "auth")
    if "auth" not in [item.strip() for item in qop.split(",")]:
        raise KeeneticEffectError("keenetic_effect_rejected")
    return fields, algorithm


def _hash(algorithm, value):
    name = "md5" if algorithm == "MD5" else "sha256"
    return hashlib.new(name, value.encode("utf-8"), usedforsecurity=False).hexdigest()


def _authorization(challenge, username, password, cnonce, *, method="POST", uri="/rci/"):
    if not _USERNAME.fullmatch(username) or not isinstance(password, str):
        raise KeeneticEffectError("keenetic_effect_unavailable")
    scheme, separator, parameters = challenge.partition(" ")
    if not separator:
        raise KeeneticEffectError("keenetic_effect_rejected")
    if scheme.lower() == "basic":
        if parameters != 'realm="Keenetic"':
            raise KeeneticEffectError("keenetic_effect_rejected")
        token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
        return "Basic " + token
    if scheme.lower() != "digest":
        raise KeeneticEffectError("keenetic_effect_rejected")
    fields, algorithm = _digest_parameters(parameters)
    if not re.fullmatch(r"[0-9a-f]{16,64}", cnonce):
        raise KeeneticEffectError("keenetic_effect_unavailable")
    nonce = fields["nonce"]
    ha1 = _hash(algorithm, f"{username}:{fields['realm']}:{password}")
    if method not in {"GET", "POST"} or not re.fullmatch(r"/[A-Za-z0-9/_-]{1,256}", uri):
        raise KeeneticEffectError("keenetic_effect_rejected")
    ha2 = _hash(algorithm, f"{method}:{uri}")
    digest = _hash(algorithm, f"{ha1}:{nonce}:00000001:{cnonce}:auth:{ha2}")
    values = [
        f'username="{username}"',
        'realm="Keenetic"',
        f'nonce="{nonce}"',
        f'uri="{uri}"',
        f"algorithm={algorithm}",
        f'response="{digest}"',
        "qop=auth",
        "nc=00000001",
        f'cnonce="{cnonce}"',
    ]
    opaque = fields.get("opaque")
    if opaque is not None:
        if not 1 <= len(opaque) <= 256:
            raise KeeneticEffectError("keenetic_effect_rejected")
        values.append(f'opaque="{opaque}"')
    return "Digest " + ", ".join(values)


def _validate_target(command):
    expected = command.expectedState
    operation = command.operation
    allowed = {
        "guest_wifi_enable": ("guest_wifi", "disabled", _WIFI),
        "guest_wifi_disable": ("guest_wifi", "enabled", _WIFI),
        "client_access_pause": ("client", "allowed", _MAC),
        "client_access_resume": ("client", "paused", _MAC),
        "wan_reconnect": ("wan", "online", _INTERFACE),
    }[operation]
    if (
        expected.targetKind != allowed[0]
        or expected.value != allowed[1]
        or allowed[2].fullmatch(expected.targetId) is None
    ):
        raise KeeneticEffectError("keenetic_effect_rejected")
    return expected


def _batch(command):
    target = command.expectedState.targetId
    if command.operation.startswith("guest_wifi_"):
        enabled = command.operation == "guest_wifi_enable"
        changes = [
            {"parse": f"interface {target} {'up' if enabled else 'down'}"},
            {"parse": "system configuration save"},
        ]
        readback = {"show": {"interface": {}}}
    elif command.operation.startswith("client_access_"):
        permit = command.operation == "client_access_resume"
        changes = [
            {"parse": f"ip hotspot host {target} {'permit' if permit else 'deny'}"},
            {"parse": "system configuration save"},
        ]
        readback = {"show": {"ip": {"hotspot": {}}}}
    else:
        changes = [
            {"parse": f"interface {target} no connect"},
            {"parse": f"interface {target} connect"},
        ]
        readback = {"show": {"interface": {}}}
    return changes + [{"show": {"version": {}}}, readback]


def _unwrap(value, key):
    if not isinstance(value, dict):
        raise ValueError
    if key in value:
        return value[key]
    show = value.get("show")
    if isinstance(show, dict) and key in show:
        return show[key]
    raise ValueError


def _command_result(value):
    if not isinstance(value, dict) or value.get("error") is not None:
        raise ValueError
    status = value.get("status")
    if status == "ok":
        return
    if isinstance(status, list) and status and all(
        isinstance(item, dict) and item.get("status") not in {"error", "failed"}
        for item in status
    ):
        return
    raise ValueError


def _observed(command, body):
    expected = command.expectedState
    if not isinstance(body, bytes) or len(body) > _MAX_RESPONSE:
        raise ValueError
    decoded = json.loads(body.decode("utf-8"))
    if not isinstance(decoded, list) or len(decoded) != 4:
        raise ValueError
    _command_result(decoded[0])
    _command_result(decoded[1])
    version = _unwrap(decoded[2], "version")
    if (
        not isinstance(version, dict)
        or version.get("release") != expected.firmwareVersion
        or version.get("revision") != expected.firmwareRevision
    ):
        raise ValueError
    readback = decoded[3]
    if expected.targetKind == "client":
        ip = _unwrap(readback, "ip")
        hotspot = ip.get("hotspot") if isinstance(ip, dict) else None
        hosts = hotspot.get("host") if isinstance(hotspot, dict) else None
        matches = [item for item in hosts or () if isinstance(item, dict)
                   and item.get("mac") == expected.targetId]
        if len(matches) != 1:
            raise ValueError
        record = matches[0]
        value = {"deny": "paused", "permit": "allowed"}.get(record.get("access"))
    else:
        interfaces = _unwrap(readback, "interface")
        if not isinstance(interfaces, dict):
            raise ValueError
        record = interfaces.get(expected.targetId)
        if not isinstance(record, dict) or record.get("id", expected.targetId) != expected.targetId:
            raise ValueError
        if expected.targetKind == "guest_wifi":
            value = {"yes": "enabled", "no": "disabled", True: "enabled", False: "disabled"}.get(record.get("up"))
        else:
            value = {"yes": "online", "no": "offline", True: "online", False: "offline"}.get(record.get("connected"))
    if record.get("revision") != expected.stateRevision + 1:
        raise ValueError
    action = {
        "guest_wifi_enable": "guest_wifi_enable",
        "guest_wifi_disable": "guest_wifi_disable",
        "client_access_pause": "client_internet_pause",
        "client_access_resume": "client_internet_resume",
        "wan_reconnect": "wan_reconnect",
    }[command.operation]
    if value != RESULT[action]:
        raise ValueError
    return expected.model_copy(
        update={"value": value, "stateRevision": expected.stateRevision + 1}
    )


class KeeneticRciTransport:
    """Load one exact service revision, then issue one authenticated mutation."""

    def __init__(
        self,
        services,
        actor,
        *,
        transport_factory=ServiceTransport,
        resolver=None,
        connector=None,
        cnonce_factory=None,
        allow_loopback_fixture=False,
        allowed_addresses=None,
    ):
        self._services = services
        self._actor = actor
        self._factory = transport_factory
        self._resolver = resolver or _system_resolver
        self._connector = connector
        self._cnonce = cnonce_factory or (lambda: secrets.token_hex(16))
        self._fixture = allow_loopback_fixture is True
        self._allowed_addresses = (
            None if allowed_addresses is None else frozenset(allowed_addresses)
        )

    def __repr__(self):
        return "KeeneticRciTransport(<private>)"

    def __call__(self, command, *, deadline, cancelled):
        try:
            command = RciCommand.model_validate(command)
        except ValidationError:
            raise KeeneticEffectError("keenetic_effect_rejected") from None
        if (
            type(deadline) not in (int, float)
            or not math.isfinite(deadline)
            or not callable(cancelled)
        ):
            raise KeeneticEffectError("keenetic_effect_rejected")
        expected = _validate_target(command)
        if command.credentialLease is not None:
            raise KeeneticEffectError("keenetic_effect_rejected")
        if cancelled():
            raise KeeneticEffectError("keenetic_effect_cancelled")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise KeeneticEffectError("keenetic_effect_timeout")
        try:
            connection = self._services.connection(
                self._actor, expected.serviceId, expected.serviceRevision
            )
            if (
                connection.kind != "keenetic"
                or connection.id != expected.serviceId
                or connection.revision != expected.serviceRevision
                or set(connection.credentials) != {"username", "password"}
            ):
                raise ValueError
            username = connection.credentials["username"]
            password = connection.credentials["password"]
            endpoint = urlsplit(connection.base_url)
            if (
                not isinstance(username, str)
                or not isinstance(password, str)
                or endpoint.scheme not in {"http", "https"}
                or endpoint.hostname is None
                or endpoint.username is not None
                or endpoint.password is not None
                or endpoint.path not in {"", "/"}
                or endpoint.query
                or endpoint.fragment
            ):
                raise ValueError
        except (ApiError, AttributeError, KeyError, TypeError, ValueError):
            raise KeeneticEffectError("keenetic_effect_unavailable") from None

        pinned = _PinnedResolver(self._resolver)
        def guard(address):
            keenetic_lan_address(
                address, allow_loopback_fixture=self._fixture
            )
            if (
                self._allowed_addresses is not None
                and address not in self._allowed_addresses
            ):
                raise ProbeTransportError("address_blocked")
        transport = None
        posted = False
        try:
            transport = self._factory(
                connection.base_url,
                timeout=min(10.0, remaining),
                max_bytes=_MAX_RESPONSE,
                resolver=pinned,
                connector=self._connector,
                address_guard=guard,
            )
            challenged = transport.request(
                "GET", "/rci/show/version", headers={"Accept": "application/json"}
            )
            if challenged.status != 401:
                raise KeeneticEffectError("keenetic_effect_rejected")
            authorization = _authorization(
                _one_header(challenged, "www-authenticate"),
                username,
                password,
                self._cnonce(),
            )
            if cancelled():
                raise KeeneticEffectError("keenetic_effect_cancelled")
            if time.monotonic() >= deadline:
                raise KeeneticEffectError("keenetic_effect_timeout")
            payload = json.dumps(
                _batch(command), separators=(",", ":"), ensure_ascii=True
            ).encode("ascii")

            def before_send():
                nonlocal posted
                if cancelled():
                    raise KeeneticEffectError("keenetic_effect_cancelled")
                if time.monotonic() >= deadline:
                    raise KeeneticEffectError("keenetic_effect_timeout")
                posted = True

            response = transport.request(
                "POST",
                "/rci/",
                headers={
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": authorization,
                },
                body=payload,
                before_send=before_send,
            )
            if response.status == 401:
                raise KeeneticEffectError("keenetic_effect_rejected")
            if response.status != 200:
                raise KeeneticEffectError(
                    "keenetic_effect_unknown", uncertain=True
                )
            try:
                result = _observed(command, response.body)
            except (UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError):
                raise KeeneticEffectError(
                    "keenetic_result_unknown", uncertain=True
                ) from None
            if cancelled() or time.monotonic() >= deadline:
                raise KeeneticEffectError(
                    "keenetic_effect_timeout", uncertain=True
                )
            return result
        except KeeneticEffectError:
            raise
        except ProbeTransportError as error:
            if error.code == "request_timeout":
                raise KeeneticEffectError(
                    "keenetic_effect_timeout", uncertain=posted
                ) from None
            raise KeeneticEffectError(
                "keenetic_effect_unknown" if posted else "keenetic_effect_unavailable",
                uncertain=posted,
            ) from None
        except Exception:
            raise KeeneticEffectError(
                "keenetic_effect_unknown" if posted else "keenetic_effect_unavailable",
                uncertain=posted,
            ) from None
        finally:
            if transport is not None:
                try:
                    transport.close()
                except Exception:
                    pass


class LeasedKeeneticRciTransport:
    """Worker-side RCI transport; the only binding input is a sealed lease."""

    def __init__(self, verifier, **transport_options):
        self._verifier = verifier
        self._options = dict(transport_options)

    def __repr__(self):
        return "LeasedKeeneticRciTransport(<private>)"

    def __call__(self, command, *, deadline, cancelled):
        command = RciCommand.model_validate(command)
        if command.credentialLease is None:
            raise KeeneticEffectError("keenetic_effect_unavailable")
        try:
            with self._verifier.open(
                command.credentialLease, command.expectedState
            ) as leased:
                connection = ServiceConnection(
                    id=leased.service_id,
                    revision=leased.service_revision,
                    name="leased-keenetic",
                    kind="keenetic",
                    base_url=leased.endpoint_text(),
                    credentials={
                        "username": leased.username_text(),
                        "password": leased.password_text(),
                    },
                )

                class OneConnection:
                    def connection(self, _actor, service_id, revision):
                        if (service_id, revision) != (
                            connection.id, connection.revision
                        ):
                            raise ApiError("revision_conflict", 409)
                        return connection

                direct = KeeneticRciTransport(
                    OneConnection(), None,
                    allowed_addresses=leased.allowed_addresses,
                    **self._options,
                )
                return direct(
                    command.model_copy(update={"credentialLease": None}),
                    deadline=deadline,
                    cancelled=cancelled,
                )
        except KeeneticEffectError:
            raise
        except KeeneticLeaseError:
            raise KeeneticEffectError("keenetic_effect_unavailable") from None
