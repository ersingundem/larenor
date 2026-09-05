"""Fixed read-only network-service probes; no configuration/device operations.

Protocol evidence reviewed 2026-09-05:
https://github.com/proxmox/pve-manager/blob/master/PVE/API2.pm
https://github.com/proxmox/pve-access-control/blob/master/src/PVE/API2/AccessControl.pm
https://github.com/esphome/device-builder/blob/main/tests/test_version_endpoint.py
https://github.com/esphome/device-builder/blob/main/esphome_device_builder/device_builder.py
https://storage.googleapis.com/docs.help.keenetic.com/cli/3.1/en/cli_manual_kn-1310_tr.pdf

Keenetic Web UI challenge hashing matches the existing Flutter KeeneticClient;
the vendor command reference establishes the read-only /rci/show/version route.
KeenDNS Digest/proxy and interactive MFA are not emulated. ESPHome /version is
public even when dashboard authentication is enabled, so no credential is sent.
"""

import hashlib
import json
import re
from urllib.parse import urlencode

from .probe import _ProbeStop, _object, _require, _session_cookie, _version


_AUTH_PARAMETER = re.compile(r'\s*([A-Za-z_][A-Za-z0-9_-]*)="([^"\\]*)"\s*(?:,\s*)?')
_USER_REALM = re.compile(r"[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+\Z")
_TOKEN_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\Z")
_TOKEN_SECRET = re.compile(r"[A-Za-z0-9_-]{1,256}\Z")
_SESSION_VALUE = re.compile(r"[A-Za-z0-9_./~+!:=@-]{1,2048}\Z")


def _one_header(response, name, *, required=True):
    values = [value for key, value in response.headers if key.lower() == name]
    _require(len(values) == 1 if required else len(values) <= 1)
    if not values:
        return None
    value = values[0]
    _require(isinstance(value, str) and 1 <= len(value) <= 4096)
    _require(all(32 <= ord(char) < 127 for char in value))
    return value


def _keenetic_cookie_name(response, realm, challenge):
    authenticate = _one_header(response, "www-authenticate", required=False)
    if authenticate is None:
        return "session_id", None
    scheme, separator, parameters = authenticate.partition(" ")
    _require(separator and scheme.lower() == "x-ndw2-interactive")
    values = {}
    position = 0
    while position < len(parameters):
        match = _AUTH_PARAMETER.match(parameters, position)
        _require(match is not None)
        name, value = match.groups()
        _require(name not in values and name in {"realm", "challenge", "session_cookie", "session_id"})
        values[name] = value
        position = match.end()
    _require(values.get("realm") == realm and values.get("challenge") == challenge)
    name = values.get("session_cookie")
    _require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,80}", name) is not None)
    return name, values.get("session_id")


def _cookie_if_present(response, login_url, name):
    if not any(key.lower() == "set-cookie" and raw.split(";", 1)[0].partition("=")[0].strip() == name
               for key, raw in response.headers):
        return None
    return _session_cookie(response, login_url, name=name)


def _open_session_headers(probe, response):
    """Keep an issued open session without treating it as credential proof."""
    base = probe.connection.base_url.rstrip("/")
    names = [raw.split(";", 1)[0].partition("=")[0].strip()
             for key, raw in response.headers if key.lower() == "set-cookie"]
    _require(len(names) <= 16 and len(set(names)) == len(names))
    values = []
    for name in names:
        cookie = _session_cookie(response, base + "/auth", name=name)
        probe.remember_secret(cookie.value)
        values.append(cookie.header(base + "/rci/show/version"))
    header = "; ".join(values)
    _require(len(header) <= 4096)
    return {"Cookie": header} if header else {}


def _keenetic(probe):
    credentials = probe.credentials
    _require(not credentials or set(credentials) == {"username", "password"})
    response = probe.request("GET", "/auth", allow_auth_challenge=True)
    headers = {}
    authenticated = False
    if response.status == 401:
        if not credentials:
            raise _ProbeStop("unauthorized")
        realm = _one_header(response, "x-ndm-realm")
        challenge = _one_header(response, "x-ndm-challenge")
        name, session_id = _keenetic_cookie_name(response, realm, challenge)
        base = probe.connection.base_url.rstrip("/")
        login_url = base + "/auth"
        cookie = _cookie_if_present(response, login_url, name)
        if cookie is not None:
            _require(session_id is None or session_id == cookie.value)
            probe.remember_secret(cookie.value)
            headers["Cookie"] = cookie.header(login_url)
        hashed = hashlib.md5(f'{credentials["username"]}:{realm}:{credentials["password"]}'.encode("utf-8"), usedforsecurity=False).hexdigest()
        digest = hashlib.sha256((challenge + hashed).encode("utf-8")).hexdigest()
        probe.remember_secret(hashed)
        probe.remember_secret(digest)
        body = json.dumps({"login": credentials["username"], "password": digest}, separators=(",", ":")).encode("utf-8")
        response = probe.request("POST", "/auth", {**headers, "Content-Type": "application/json"}, body)
        replacement = _cookie_if_present(response, login_url, name)
        cookie = replacement if replacement is not None else cookie
        _require(cookie is not None)
        probe.remember_secret(cookie.value)
        headers = {"Cookie": cookie.header(base + "/rci/show/version")}
        authenticated = True
    else:
        headers = _open_session_headers(probe, response)
    data = probe.get_object("/rci/show/version", headers)
    _require(isinstance(data.get("model"), str) and 1 <= len(data["model"]) <= 128)
    _require(data.get("manufacturer") == "Keenetic Ltd." or
             isinstance(data.get("hw_id"), str) and re.fullmatch(r"KN-[0-9]{4}", data["hw_id"]) is not None)
    version = _version(data.get("release") or data.get("title"), credentials)
    return probe.result(version, authenticated=authenticated)


def _user_realm(value):
    _require(isinstance(value, str) and 1 <= len(value) <= 64 and _USER_REALM.fullmatch(value) is not None)
    return value


def _proxmox(probe):
    credentials = probe.credentials
    keys = set(credentials)
    _require(not keys or keys in ({"token"}, {"username", "password"}))
    headers = {}
    if keys == {"token"}:
        identity, separator, secret = credentials["token"].partition("=")
        user, bang, token_id = identity.partition("!")
        _user_realm(user)
        _require(separator and bang and _TOKEN_ID.fullmatch(token_id) is not None and _TOKEN_SECRET.fullmatch(secret) is not None)
        probe.remember_secret(secret)
        headers = {"Authorization": "PVEAPIToken=" + credentials["token"]}
    elif credentials:
        _user_realm(credentials["username"])
    authenticated = False
    try:
        data = probe.get_object("/api2/json/version")
    except _ProbeStop as error:
        if error.state != "unauthorized" or not credentials:
            raise
        if not headers:
            response = probe.request("POST", "/api2/json/access/ticket",
                                     {"Content-Type": "application/x-www-form-urlencoded"},
                                     urlencode(credentials).encode("ascii"))
            login = _object(response).get("data")
            _require(type(login) is dict)
            ticket, csrf = login.get("ticket"), login.get("CSRFPreventionToken")
            if login.get("NeedTFA") in (1, True) or isinstance(ticket, str) and "!tfa!" in ticket:
                raise _ProbeStop("unauthorized")
            _require(login.get("NeedTFA") is None or login.get("NeedTFA") is False or type(login.get("NeedTFA")) is int and login["NeedTFA"] == 0)
            _require(login.get("username") == credentials["username"])
            _require(isinstance(ticket, str) and _SESSION_VALUE.fullmatch(ticket) is not None and
                     ticket.startswith("PVE:" + credentials["username"] + ":"))
            _require(isinstance(csrf, str) and _SESSION_VALUE.fullmatch(csrf) is not None)
            probe.remember_secret(ticket)
            probe.remember_secret(csrf)
            headers = {"Cookie": "PVEAuthCookie=" + ticket}
        data = probe.get_object("/api2/json/version", headers)
        authenticated = True
    data = data.get("data")
    _require(type(data) is dict)
    _require(isinstance(data.get("release"), str) and re.fullmatch(r"[0-9]+\.[0-9]+", data["release"]) is not None)
    _require(isinstance(data.get("repoid"), str) and re.fullmatch(r"[0-9a-fA-F]{8,64}", data["repoid"]) is not None)
    return probe.result(_version(data.get("version"), credentials), authenticated=authenticated)


def network_probe(probe):
    """Run one fixed family adapter using the caller's shared deadline/transport."""
    if probe.connection.kind == "keenetic":
        return _keenetic(probe)
    if probe.connection.kind == "proxmox":
        return _proxmox(probe)
    if probe.connection.kind == "esphome":
        data = probe.get_object("/version")
        version = _version(data.get("version"), probe.credentials)
        _require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9._+\-]*", version) is not None)
        return probe.result(version)
    raise _ProbeStop()
