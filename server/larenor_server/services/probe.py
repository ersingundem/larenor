"""Read-only service identity probes; credentials and source replies stay private.

API evidence (official documentation/source, reviewed 2026-09-05):
https://developers.home-assistant.io/docs/api/rest/
https://github.com/Sonarr/Sonarr/blob/develop/src/Sonarr.Api.V3/System/SystemController.cs
https://github.com/Radarr/Radarr/blob/develop/src/Radarr.Api.V3/System/SystemController.cs
https://github.com/Lidarr/Lidarr/blob/develop/src/Lidarr.Api.V1/System/SystemController.cs
https://github.com/Readarr/Readarr/blob/develop/src/Readarr.Api.V1/System/SystemController.cs
https://github.com/Prowlarr/Prowlarr/blob/develop/src/Prowlarr.Api.V1/System/SystemController.cs
https://github.com/morpheus65535/bazarr/blob/master/bazarr/api/system/status.py
https://github.com/morpheus65535/bazarr/blob/master/bazarr/api/utils.py
https://docs.seerr.dev/api/seerr-api/
https://github.com/seerr-team/seerr/blob/develop/server/routes/auth.ts
https://github.com/seerr-team/seerr/blob/develop/server/routes/index.ts
https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/SystemController.cs
https://github.com/immich-app/immich/blob/main/server/src/controllers/server.controller.ts
https://github.com/AdguardTeam/AdGuardHome/blob/master/openapi/openapi.yaml
https://github.com/blakeblackshear/frigate/blob/dev/frigate/api/app.py
https://www.music-assistant.io/api/
https://github.com/music-assistant/server/blob/dev/music_assistant/mass.py
https://github.com/music-assistant/server/blob/dev/music_assistant/controllers/webserver/controller.py
https://github.com/qbittorrent/qBittorrent/blob/release-5.1.2/src/webui/api/authcontroller.cpp
https://github.com/qbittorrent/qBittorrent/blob/release-5.1.2/src/webui/webapplication.cpp

Keenetic, Proxmox and ESPHome use the packaged network_probes module. Frigate
and ESPHome prove public identity only. Seerr uses public settings, avoiding the status endpoint's
optional outbound update check. qBittorrent supports the documented SID login;
other session names/authentication modes remain explicitly unsupported.
"""

import base64
from collections.abc import Mapping
from dataclasses import dataclass, field
from email.utils import parsedate_to_datetime
import json
import math
import re
import time
from urllib.parse import urlencode, urlsplit

from .service import ServiceConnection
from .transport import ProbeResponse, ProbeTransportError, ServiceTransport


_BUDGET = 12.0
_MAX_REPLY = 65536
_VERSION = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._+:/()\-]{0,79}\Z")
_PLAIN_VERSION = re.compile(r"v?[0-9]+\.[0-9]+(?:[.A-Za-z0-9_+\-]*)\Z")
_ARR = {"sonarr": "v3", "radarr": "v3", "lidarr": "v1", "readarr": "v1", "prowlarr": "v1"}
_SUPPORTED = frozenset({*_ARR, "bazarr", "home_assistant", "seerr", "jellyfin", "immich", "adguard", "frigate", "music_assistant", "qbittorrent", "keenetic", "proxmox", "esphome"})
_NETWORK_ERRORS = frozenset({"request_timeout", "resolution_failed", "request_failed", "tls_failed", "transport_closed"})


@dataclass(frozen=True)
class ProbeResult:
    state: str
    version: str | None = None


class _ProbeStop(Exception):
    def __init__(self, state="unsupported"):
        self.state = state
        super().__init__(state)


def _require(condition):
    if not condition:
        raise _ProbeStop()


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        _require(key not in result)
        result[key] = value
    return result


def _invalid_constant(_value):
    raise _ProbeStop()


def _finite_float(value):
    result = float(value)
    _require(math.isfinite(result))
    return result


def _object(response):
    content_types = [value for key, value in response.headers if key.lower() == "content-type"]
    _require(len(content_types) <= 1)
    if content_types:
        _require(content_types[0].split(";", 1)[0].strip().lower() == "application/json")
    value = json.loads(response.body.decode("utf-8"), object_pairs_hook=_unique_object, parse_constant=_invalid_constant, parse_float=_finite_float)
    _require(type(value) is dict)
    return value


def _version(value, credentials):
    _require(isinstance(value, str) and _VERSION.fullmatch(value) is not None)
    # A compromised service must not turn a credential echo into public metadata.
    _require(not any(secret in value for secret in credentials.values()))
    return value


def _text_version(response, credentials):
    value = response.body.decode("ascii").strip()
    _require(_PLAIN_VERSION.fullmatch(value) is not None)
    return _version(value, credentials)


def _credentials(connection):
    credentials = connection.credentials
    _require(isinstance(credentials, Mapping) and len(credentials) <= 5)
    size = 0
    for key, value in credentials.items():
        _require(key in {"apiKey", "token", "username", "password", "userId"})
        _require(isinstance(value, str) and 1 <= len(value) <= 2048)
        _require(not any(ord(char) < 32 or ord(char) == 127 or 0xD800 <= ord(char) <= 0xDFFF for char in value))
        size += len(value.encode("utf-8"))
    _require(size <= 4096)
    return credentials


def _key_headers(credentials, key, header, prefix=""):
    _require(not credentials or set(credentials) == {key})
    if not credentials:
        return {}
    value = prefix + credentials[key]
    # HTTP headers use Latin-1. Refuse unsupported credentials without issuing a
    # partial request or exposing the codec's raw exception message.
    value.encode("latin-1")
    return {header: value}


class _Probe:
    def __init__(self, connection, factory):
        self.connection = connection
        self.factory = factory
        self.deadline = time.monotonic() + _BUDGET
        self.credentials = _credentials(connection)
        self._secrets = dict(self.credentials)

    def remember_secret(self, value):
        """Keep an ephemeral auth value out of any public version field."""
        _require(isinstance(value, str) and 0 < len(value) <= 8192)
        self._secrets[str(len(self._secrets))] = value

    def remaining(self):
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise _ProbeStop("unavailable")
        return left

    def request(self, method, path, headers=None, body=None, *, allow_auth_challenge=False):
        _require(not allow_auth_challenge or (method == "GET" and path == "/auth"))
        transport = None
        try:
            for name, value in (headers or {}).items():
                if name.lower() == "authorization":
                    self.remember_secret(value)
                    scheme, separator, token = value.partition(" ")
                    if separator and token:
                        self.remember_secret(token)
                        if scheme.lower() == "basic":
                            self.remember_secret(token.rstrip("="))
            transport = self.factory(self.connection.base_url, timeout=min(8.0, self.remaining()), max_bytes=_MAX_REPLY)
            response = transport.request(method, path, headers=headers, body=body)
        finally:
            if transport is not None:
                transport.close()
        self.remaining()
        _require(isinstance(response, ProbeResponse) and type(response.status) is int)
        # The concrete transport enforces this before accumulation; also bound
        # injected transports and parsing here.
        _require(isinstance(response.body, bytes) and len(response.body) <= _MAX_REPLY)
        if allow_auth_challenge and response.status == 401:
            return response
        if response.status in {401, 403}:
            raise _ProbeStop("unauthorized")
        if response.status == 429 or 500 <= response.status <= 599:
            raise _ProbeStop("unavailable")
        _require(response.status == 200)
        return response

    def get_object(self, path, headers=None):
        return _object(self.request("GET", path, headers))

    def challenge_object(self, path, headers):
        # Arr can bypass authentication for local addresses; AdGuard can disable
        # authentication entirely. A public 200 proves no supplied credential.
        try:
            data = self.get_object(path)
        except _ProbeStop as error:
            if error.state != "unauthorized" or not headers:
                raise
            return self.get_object(path, headers), True
        return data, False

    def result(self, version=None, *, authenticated=False):
        self.remaining()
        return ProbeResult("authenticated" if authenticated else "reachable", None if version is None else _version(version, self._secrets))


@dataclass(frozen=True)
class _SessionCookie:
    value: str = field(repr=False)
    origin: tuple = field(repr=False)
    path: str = field(repr=False)
    secure: bool
    expires_at: float | None = field(default=None, repr=False)
    name: str = field(default="SID", repr=False)

    def header(self, url):
        parsed = urlsplit(url)
        _require(_origin(parsed) == self.origin)
        _require(not self.secure or parsed.scheme == "https")
        _require(_path_matches(parsed.path, self.path))
        _require(self.expires_at is None or time.time() < self.expires_at)
        return self.name + "=" + self.value


def _origin(parsed):
    return parsed.scheme, parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80)


def _path_matches(path, scope):
    return path == scope or (path.startswith(scope) and (scope.endswith("/") or path[len(scope):].startswith("/")))


def _session_cookie(response, login_url, *, name="SID"):
    _require(isinstance(name, str) and re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]{1,80}", name) is not None)
    parsed = urlsplit(login_url)
    found = []
    for key, raw in response.headers:
        if key.lower() != "set-cookie":
            continue
        parts = raw.split(";")
        first = parts[0].strip().partition("=")
        if first[0] != name:
            continue
        _require(len(raw) <= 4096 and not any(ord(char) < 32 or ord(char) >= 127 for char in raw))
        _require(first[1] == "=" and re.fullmatch(r"[A-Za-z0-9_./~+\-=]{1,2048}", first[2]) is not None)
        attrs = {}
        for part in parts[1:]:
            attribute, sep, value = part.strip().partition("=")
            attribute = attribute.lower()
            _require(bool(attribute) and attribute not in attrs)
            attrs[attribute] = value if sep else None
        if "domain" in attrs:
            domain = attrs["domain"]
            # Narrower than a browser: a probe never needs a parent-domain cookie.
            _require(isinstance(domain, str) and domain.lstrip(".").lower() == parsed.hostname)
        default_path = parsed.path.rsplit("/", 1)[0] or "/"
        path = attrs.get("path", default_path)
        _require(isinstance(path, str) and path.startswith("/") and not any(char in path for char in "\\?#%"))
        _require(not any(part in {".", ".."} for part in path.split("/")))
        secure = "secure" in attrs
        _require(not secure or attrs["secure"] is None)
        expires = None
        if "max-age" in attrs:
            age = attrs["max-age"]
            _require(isinstance(age, str) and re.fullmatch(r"[0-9]{1,10}", age) is not None and int(age) > 0)
            expires = time.time() + int(age)
        elif "expires" in attrs:
            date = parsedate_to_datetime(attrs["expires"])
            _require(date.tzinfo is not None)
            expires = date.timestamp()
            _require(expires > time.time())
        found.append(_SessionCookie(first[2], _origin(parsed), path, secure, expires, name))
    _require(len(found) == 1)
    return found[0]


def _qbittorrent(probe):
    credentials = probe.credentials
    _require(not credentials or set(credentials) == {"username", "password"})
    headers = {"Referer": probe.connection.base_url.rstrip("/") + "/"}
    if credentials:
        response = probe.request("POST", "/api/v2/auth/login", {**headers, "Content-Type": "application/x-www-form-urlencoded"}, urlencode(credentials).encode("ascii"))
        if response.body == b"Fails.":
            raise _ProbeStop("unauthorized")
        _require(response.body == b"Ok.")
        base = probe.connection.base_url.rstrip("/")
        cookie = _session_cookie(response, base + "/api/v2/auth/login")
        probe.remember_secret(cookie.value)
        headers["Cookie"] = cookie.header(base + "/api/v2/app/version")
    response = probe.request("GET", "/api/v2/app/version", headers)
    return probe.result(_text_version(response, credentials), authenticated=bool(credentials))


def _run(probe):
    kind, credentials = probe.connection.kind, probe.credentials
    if kind in {"keenetic", "proxmox", "esphome"}:
        from .network_probes import network_probe
        return network_probe(probe)
    if kind == "qbittorrent":
        return _qbittorrent(probe)
    if kind == "home_assistant":
        headers = _key_headers(credentials, "token", "Authorization", "Bearer ")
        data = probe.get_object("/api/config", headers)
        _require(isinstance(data.get("components"), list) and all(isinstance(item, str) for item in data["components"]))
        return probe.result(_version(data.get("version"), credentials), authenticated=bool(headers))
    if kind in _ARR:
        headers = _key_headers(credentials, "apiKey", "X-Api-Key")
        data, authenticated = probe.challenge_object(f"/api/{_ARR[kind]}/system/status", headers)
        _require(isinstance(data.get("appName"), str) and data["appName"].lower() == kind)
        return probe.result(_version(data.get("version"), credentials), authenticated=authenticated)
    if kind == "bazarr":
        headers = _key_headers(credentials, "apiKey", "X-Api-Key")
        data = probe.get_object("/api/system/status", headers)
        _require(type(data.get("data")) is dict)
        return probe.result(_version(data["data"].get("bazarr_version"), credentials), authenticated=bool(headers))
    if kind == "seerr":
        headers = _key_headers(credentials, "apiKey", "X-Api-Key")
        if headers:
            data = probe.get_object("/api/v1/auth/me", headers)
            _require(type(data.get("id")) is int and data["id"] > 0 and type(data.get("permissions")) is int and data["permissions"] >= 0)
        else:
            data = probe.get_object("/api/v1/settings/public")
            _require(type(data.get("initialized")) is bool and isinstance(data.get("applicationTitle"), str) and type(data.get("mediaServerType")) is int)
        return probe.result(authenticated=bool(headers))
    if kind == "jellyfin":
        # API keys and user access tokens both use this header; refuse ambiguous
        # combinations instead of silently choosing a different stored secret.
        key = "apiKey" if "apiKey" in credentials else "token"
        headers = _key_headers(credentials, key, "X-Emby-Token")
        data = probe.get_object("/System/Info" if headers else "/System/Info/Public", headers)
        _require(data.get("ProductName") in {"Jellyfin Server", "Jellyfin"})
        # System/Info permits first-time setup without authentication.
        if headers:
            _require(type(data.get("StartupWizardCompleted")) is bool)
        return probe.result(_version(data.get("Version"), credentials), authenticated=bool(headers) and data.get("StartupWizardCompleted") is True)
    if kind == "immich":
        key = "token" if "token" in credentials else "apiKey"
        headers = _key_headers(credentials, key, "Authorization" if key == "token" else "x-api-key", "Bearer " if key == "token" else "")
        if headers:
            data = probe.get_object("/api/server/about", headers)
            _require(type(data.get("licensed")) is bool and isinstance(data.get("versionUrl"), str))
            return probe.result(_version(data.get("version"), credentials), authenticated=True)
        data = probe.get_object("/api/server/version")
        _require(all(type(data.get(key)) is int and 0 <= data[key] <= 999999 for key in ("major", "minor", "patch")))
        version = ".".join(str(data[key]) for key in ("major", "minor", "patch"))
        if data.get("prerelease") is not None:
            _require(type(data["prerelease"]) is int and 0 <= data["prerelease"] <= 999999)
            version += "-" + str(data["prerelease"])
        return probe.result(version)
    if kind == "adguard":
        _require(not credentials or set(credentials) == {"username", "password"})
        headers = {}
        if credentials:
            _require(":" not in credentials["username"])
            value = base64.b64encode((credentials["username"] + ":" + credentials["password"]).encode("utf-8")).decode("ascii")
            headers["Authorization"] = "Basic " + value
        data, authenticated = probe.challenge_object("/control/status", headers)
        _require(type(data.get("running")) is bool and isinstance(data.get("dns_addresses"), list) and all(isinstance(item, str) for item in data["dns_addresses"]))
        return probe.result(_version(data.get("version"), credentials), authenticated=authenticated)
    if kind == "frigate":
        # The official route is allow_public(); forwarding a token here would
        # neither verify that token nor provide stronger identity evidence.
        response = probe.request("GET", "/api/version")
        return probe.result(_text_version(response, credentials))
    if kind == "music_assistant":
        headers = _key_headers(credentials, "token", "Authorization", "Bearer ")
        headers["Content-Type"] = "application/json"
        response = probe.request("POST", "/api", headers, json.dumps({"message_id": "larenor-probe", "command": "info", "args": {}}, separators=(",", ":")).encode("ascii"))
        data = _object(response)
        _require(isinstance(data.get("server_id"), str) and 1 <= len(data["server_id"]) <= 128 and type(data.get("schema_version")) is int and data["schema_version"] > 0)
        return probe.result(_version(data.get("server_version"), credentials), authenticated=bool(credentials))
    raise _ProbeStop()


def probe_connection(connection: ServiceConnection, transport_factory=ServiceTransport) -> ProbeResult:
    """Inspect only fixed identity/authentication routes within one 12s budget."""
    try:
        _require(connection.kind in _SUPPORTED)
        return _run(_Probe(connection, transport_factory))
    except _ProbeStop as error:
        return ProbeResult(error.state)
    except ProbeTransportError as error:
        return ProbeResult("unavailable" if error.code in _NETWORK_ERRORS else "unsupported")
    except (ValueError, TypeError, UnicodeError, OverflowError, RecursionError):
        return ProbeResult("unsupported")
    except (OSError, TimeoutError):
        return ProbeResult("unavailable")
