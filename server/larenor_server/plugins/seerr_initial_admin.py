"""Bounded initial Seerr administrator bootstrap over one proved stream.

The caller owns container and endpoint proof.  This adapter performs no name
resolution, connection, redirect or retry, and never exposes supplied secrets.
"""

from dataclasses import dataclass, field
import base64
import binascii
import json
import math
import re
import socket
import time

from ..services.transport import (
    ProbeTransportError,
    _Deadline,
    _remaining,
    _request_bytes,
)
from .jellyfin_startup import _ConnectionLost, _StartupReader, _headers


_CODES = frozenset(
    {
        "invalid_seerr_initial_admin",
        "seerr_initial_state_conflict",
        "seerr_initial_admin_conflict",
        "seerr_jellyfin_authentication_failed",
        "seerr_session_protocol",
        "seerr_api_key_protocol",
        "seerr_initial_admin_protocol",
        "seerr_initial_admin_unavailable",
        "seerr_initial_admin_timeout",
    }
)
_PUBLIC_FIELDS = frozenset(
    {
        "initialized",
        "applicationTitle",
        "applicationUrl",
        "hideAvailable",
        "hideBlocklisted",
        "localLogin",
        "mediaServerLogin",
        "movie4kEnabled",
        "series4kEnabled",
        "discoverRegion",
        "streamingRegion",
        "originalLanguage",
        "mediaServerType",
        "jellyfinExternalHost",
        "jellyfinForgotPasswordUrl",
        "jellyfinServerName",
        "partialRequestsEnabled",
        "enableSpecialEpisodes",
        "cacheImages",
        "vapidPublic",
        "enablePushRegistration",
        "locale",
        "emailEnabled",
        "userEmailRequired",
        "newPlexLogin",
        "youtubeUrl",
        "versionCheck",
        "plexClientIdentifier",
    }
)
_COOKIE_VALUE = re.compile(r"s%3A[A-Za-z0-9_-]{20,256}\.[A-Za-z0-9_-]{20,128}\Z")
_JELLYFIN_HOST = re.compile(r"larenor-[0-9a-f]{32}\Z")
_EXPIRES = re.compile(
    r"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), [0-9]{2} "
    r"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) "
    r"[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT\Z"
)
_GENERATED_KEY = re.compile(
    rb"[0-9]{13}[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-"
    rb"[89ab][0-9a-f]{3}-[0-9a-f]{12}\Z"
)


class SeerrInitialAdminError(Exception):
    def __init__(
        self,
        code="seerr_initial_admin_unavailable",
        *,
        completed_steps=(),
        uncertain_effect=False,
    ):
        self.code = code if code in _CODES else "seerr_initial_admin_unavailable"
        self.completed_steps = tuple(completed_steps)
        self.uncertain_effect = uncertain_effect is True
        super().__init__(self.code)

    def __repr__(self):
        return (
            f"SeerrInitialAdminError({self.code!r}, "
            f"completed_steps={len(self.completed_steps)}, "
            f"uncertain_effect={self.uncertain_effect!r})"
        )


@dataclass(frozen=True)
class SeerrInitialAdminLimits:
    total_seconds: float = 45.0
    max_response_bytes: int = 524288

    def __post_init__(self):
        if (
            type(self.total_seconds) not in (int, float)
            or not math.isfinite(self.total_seconds)
            or not 0 < self.total_seconds <= 120
            or type(self.max_response_bytes) is not int
            or not 1 <= self.max_response_bytes <= 1048576
        ):
            raise SeerrInitialAdminError("invalid_seerr_initial_admin")


@dataclass(frozen=True, repr=False)
class SeerrInitialAdminResult:
    state: str
    api_key: str = field(repr=False)
    completed_steps: tuple[str, ...]

    def __post_init__(self):
        if (
            self.state != "verified"
            or not _is_generated_key(self.api_key)
            or self.completed_steps
            != (
                "uninitialized_verified",
                "admin_created",
                "api_key_verified",
                "session_destroyed",
            )
        ):
            raise SeerrInitialAdminError("invalid_seerr_initial_admin")

    def __repr__(self):
        return (
            f"SeerrInitialAdminResult(state={self.state!r}, "
            f"completed_steps={len(self.completed_steps)})"
        )


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError()
        result[key] = value
    return result


def _json(raw, code):
    try:
        return json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_unique,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
    except (UnicodeError, json.JSONDecodeError, ValueError, TypeError):
        raise SeerrInitialAdminError(code) from None


def _is_generated_key(value):
    if type(value) is not str or not 64 <= len(value) <= 72:
        return False
    try:
        raw = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        return False
    return base64.b64encode(raw).decode("ascii") == value and bool(
        _GENERATED_KEY.fullmatch(raw)
    )


def _body(reader, headers, maximum, status):
    framing = {}
    for name, value in headers:
        if name in {
            "content-length",
            "transfer-encoding",
            "content-encoding",
            "content-type",
            "connection",
        }:
            if name in framing:
                raise ProbeTransportError("invalid_response")
            framing[name] = value.lower()
    if (
        framing.get("content-encoding", "identity") != "identity"
        or framing.get("content-type", "").split(";")[0].strip() != "application/json"
    ):
        raise ProbeTransportError("invalid_response")
    connection = framing.get("connection")
    if connection not in (None, "keep-alive", "close"):
        raise ProbeTransportError("invalid_response")
    length, transfer = framing.get("content-length"), framing.get("transfer-encoding")
    if transfer not in (None, "chunked") or length is not None and transfer is not None:
        raise ProbeTransportError("invalid_response")
    if status == 204:
        if transfer is not None or length not in (None, "0"):
            raise ProbeTransportError("invalid_response")
        return b"", connection == "close"
    if length is not None:
        if re.fullmatch(r"[0-9]{1,20}", length) is None or int(length) > maximum:
            raise ProbeTransportError("response_too_large")
        return reader.exact(int(length)), connection == "close"
    if transfer != "chunked":
        raise ProbeTransportError("invalid_response")
    body = bytearray()
    for _ in range(256):
        line = reader.line(128)
        if re.fullmatch(rb"[0-9A-Fa-f]{1,16}\r\n", line) is None:
            raise ProbeTransportError("invalid_response")
        size = int(line[:-2], 16)
        if size > maximum - len(body):
            raise ProbeTransportError("response_too_large")
        if size == 0:
            if reader.line(8192) != b"\r\n":
                raise ProbeTransportError("invalid_response")
            return bytes(body), connection == "close"
        body.extend(reader.exact(size))
        if reader.exact(2) != b"\r\n":
            raise ProbeTransportError("invalid_response")
    raise ProbeTransportError("response_too_large")


def _response(reader, maximum):
    status, headers = _headers(reader)
    body, closes = _body(reader, headers, maximum, status)
    return status, headers, body, closes


def _session(headers):
    cookies = [value for name, value in headers if name == "set-cookie"]
    if len(cookies) != 1:
        raise SeerrInitialAdminError("seerr_session_protocol")
    parts = cookies[0].split("; ")
    if not parts or not parts[0].startswith("connect.sid="):
        raise SeerrInitialAdminError("seerr_session_protocol")
    value = parts[0][len("connect.sid=") :]
    attributes = parts[1:]
    if (
        _COOKIE_VALUE.fullmatch(value) is None
        or "Path=/" not in attributes
        or "HttpOnly" not in attributes
        or "SameSite=Lax" not in attributes
        or len(attributes) != len(set(attributes))
        or any(
            item not in {"Path=/", "HttpOnly", "SameSite=Lax"}
            and not (item.startswith("Expires=") and _EXPIRES.fullmatch(item[8:]))
            and not (
                item.startswith("Max-Age=") and re.fullmatch(r"[0-9]{1,10}", item[8:])
            )
            for item in attributes
        )
    ):
        raise SeerrInitialAdminError("seerr_session_protocol")
    return value


def _wire(method, path, body=None, *, cookie=None, final=False):
    headers = {"Accept": "application/json"}
    raw = None
    if body is not None:
        raw = json.dumps(body, sort_keys=True, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif method == "POST":
        headers["Content-Type"] = "application/json"
    if cookie is not None:
        headers["Cookie"] = "connect.sid=" + cookie
    request = _request_bytes(method, path, "seerr", headers, raw)
    if not final:
        request = request.replace(
            b"Connection: close\r\n", b"Connection: keep-alive\r\n", 1
        )
    return request


class SeerrInitialAdmin:
    def create(
        self,
        connection,
        *,
        username,
        credential,
        jellyfin_hostname,
        limits=SeerrInitialAdminLimits(),
        close_connection=True,
    ):
        if (
            username != "larenor-system"
            or type(credential) is not str
            or not 32 <= len(credential) <= 128
            or re.fullmatch(r"[A-Za-z0-9_-]+", credential) is None
            or type(jellyfin_hostname) is not str
            or _JELLYFIN_HOST.fullmatch(jellyfin_hostname) is None
            or type(limits) is not SeerrInitialAdminLimits
            or type(close_connection) is not bool
            or any(
                not callable(getattr(connection, name, None))
                for name in ("sendall", "recv", "settimeout", "shutdown", "close")
            )
        ):
            raise SeerrInitialAdminError("invalid_seerr_initial_admin")
        try:
            limits = SeerrInitialAdminLimits(**vars(limits))
        except (ValueError, TypeError, AttributeError, SeerrInitialAdminError):
            raise SeerrInitialAdminError("invalid_seerr_initial_admin") from None

        deadline = time.monotonic() + limits.total_seconds
        completed = []
        mutation_sent = False
        scope = None
        protocol_code = "seerr_initial_admin_protocol"
        try:
            scope = _Deadline(deadline)
            scope.attach(connection)
            reader = _StartupReader(connection, deadline)

            status, _headers_value, raw, closes = self._request(
                connection,
                reader,
                deadline,
                limits,
                "GET",
                "/api/v1/settings/public",
            )
            public = _json(raw, "seerr_initial_state_conflict")
            if (
                status != 200
                or closes
                or type(public) is not dict
                or not set(public) <= _PUBLIC_FIELDS
                or public.get("initialized") is not False
                or public.get("applicationTitle") != "Seerr"
            ):
                raise SeerrInitialAdminError("seerr_initial_state_conflict")
            completed.append("uninitialized_verified")

            mutation_sent = True
            status, headers, raw, closes = self._request(
                connection,
                reader,
                deadline,
                limits,
                "POST",
                "/api/v1/auth/jellyfin",
                {
                    "username": username,
                    "password": credential,
                    "hostname": jellyfin_hostname,
                    "port": 8096,
                    "urlBase": "",
                    "useSsl": False,
                    "email": username,
                    "serverType": 2,
                },
            )
            if status in {401, 403}:
                mutation_sent = False
                raise SeerrInitialAdminError("seerr_jellyfin_authentication_failed")
            if status != 200 or closes:
                raise SeerrInitialAdminError(protocol_code)
            user = _json(raw, "seerr_initial_admin_conflict")
            if (
                type(user) is not dict
                or user.get("id") != 1
                or type(user.get("permissions")) is not int
                or not user["permissions"] & 2
                or user.get("userType") != 3
                or user.get("jellyfinUsername") != username
            ):
                raise SeerrInitialAdminError("seerr_initial_admin_conflict")
            cookie = _session(headers)
            completed.append("admin_created")

            status, _headers_value, raw, closes = self._request(
                connection,
                reader,
                deadline,
                limits,
                "GET",
                "/api/v1/settings/main",
                cookie=cookie,
            )
            main = _json(raw, "seerr_api_key_protocol")
            api_key = main.get("apiKey") if type(main) is dict else None
            if (
                status != 200
                or closes
                or type(main) is not dict
                or main.get("mediaServerType") != 2
                or not _is_generated_key(api_key)
            ):
                raise SeerrInitialAdminError("seerr_api_key_protocol")
            completed.append("api_key_verified")

            status, _headers_value, raw, _closes = self._request(
                connection,
                reader,
                deadline,
                limits,
                "POST",
                "/api/v1/auth/logout",
                cookie=cookie,
                final=close_connection,
            )
            if status != 200 or _json(raw, protocol_code) != {"status": "ok"}:
                raise SeerrInitialAdminError(protocol_code)
            completed.append("session_destroyed")
            return SeerrInitialAdminResult("verified", api_key, tuple(completed))
        except SeerrInitialAdminError as error:
            if error.completed_steps or error.uncertain_effect:
                raise
            raise SeerrInitialAdminError(
                error.code,
                completed_steps=completed,
                uncertain_effect=mutation_sent,
            ) from None
        except (socket.timeout, TimeoutError):
            raise SeerrInitialAdminError(
                "seerr_initial_admin_timeout",
                completed_steps=completed,
                uncertain_effect=mutation_sent,
            ) from None
        except _ConnectionLost:
            raise SeerrInitialAdminError(
                "seerr_initial_admin_unavailable",
                completed_steps=completed,
                uncertain_effect=mutation_sent,
            ) from None
        except (
            ProbeTransportError,
            ValueError,
            TypeError,
            AttributeError,
            UnicodeError,
            json.JSONDecodeError,
        ):
            code = (
                "seerr_initial_admin_timeout"
                if time.monotonic() >= deadline
                else protocol_code
            )
            raise SeerrInitialAdminError(
                code,
                completed_steps=completed,
                uncertain_effect=mutation_sent,
            ) from None
        except (OSError, RuntimeError):
            code = (
                "seerr_initial_admin_timeout"
                if time.monotonic() >= deadline
                else "seerr_initial_admin_unavailable"
            )
            raise SeerrInitialAdminError(
                code,
                completed_steps=completed,
                uncertain_effect=mutation_sent,
            ) from None
        finally:
            if scope is not None:
                if not close_connection:
                    scope.timer.cancel()
                    with scope.lock:
                        scope.socket = None
                scope.finish()

    @staticmethod
    def _request(
        connection,
        reader,
        deadline,
        limits,
        method,
        path,
        body=None,
        *,
        cookie=None,
        final=False,
    ):
        connection.settimeout(_remaining(deadline))
        connection.sendall(
            _wire(
                method,
                path,
                body,
                cookie=cookie,
                final=final,
            )
        )
        return _response(reader, limits.max_response_bytes)
