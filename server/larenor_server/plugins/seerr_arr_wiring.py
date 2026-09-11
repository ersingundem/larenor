"""Bounded Seerr Sonarr/Radarr wiring over one proved private connection.

Endpoint and body shapes follow Seerr's pinned settings API. The caller proves
the container identities and owns the connection; this adapter never resolves a
name, follows a redirect, selects an unobserved profile, or exposes credentials.
"""

from dataclasses import dataclass
import json
import math
import re
import socket
import time

from ..services.transport import ProbeTransportError, _Deadline, _remaining, _request_bytes
from .jellyfin_startup import _ConnectionLost, _StartupReader, _response
from .seerr_initial_admin import _is_generated_key


_HOST = re.compile(r"larenor-[0-9a-f]{32}\Z")
_ARR_KEY = re.compile(r"[0-9a-f]{32}\Z")
_CODES = frozenset(
    {
        "invalid_seerr_arr_service",
        "invalid_seerr_arr_wiring",
        "seerr_arr_conflict",
        "seerr_arr_selection_changed",
        "seerr_arr_protocol",
        "seerr_arr_unavailable",
        "seerr_arr_timeout",
    }
)


class SeerrArrWiringError(Exception):
    def __init__(self, code="seerr_arr_unavailable", *, uncertain_effect=False):
        self.code = code if code in _CODES else "seerr_arr_unavailable"
        self.uncertain_effect = uncertain_effect is True
        super().__init__(self.code)

    def __repr__(self):
        return (
            f"SeerrArrWiringError({self.code!r}, "
            f"uncertain_effect={self.uncertain_effect!r})"
        )


@dataclass(frozen=True, repr=False)
class SeerrArrService:
    service_id: str
    hostname: str
    port: int
    api_key: str
    profile_id: int
    profile_name: str
    root_path: str

    def __post_init__(self):
        expected = {
            "radarr": (7878, "/media/movies"),
            "sonarr": (8989, "/media/tv"),
        }.get(self.service_id)
        if (
            expected is None
            or _HOST.fullmatch(self.hostname) is None
            or type(self.port) is not int
            or self.port != expected[0]
            or _ARR_KEY.fullmatch(self.api_key) is None
            or type(self.profile_id) is not int
            or not 1 <= self.profile_id <= 2**31 - 1
            or type(self.profile_name) is not str
            or not 1 <= len(self.profile_name) <= 128
            or self.profile_name != self.profile_name.strip()
            or any(ord(char) < 32 or ord(char) == 127 for char in self.profile_name)
            or self.root_path != expected[1]
        ):
            raise SeerrArrWiringError("invalid_seerr_arr_service")

    def __repr__(self):
        return f"SeerrArrService(service_id={self.service_id!r}, <private>)"


@dataclass(frozen=True)
class SeerrArrWiringResult:
    state: str
    service_ids: tuple[str, ...]
    instance_ids: tuple[int, ...]

    def __post_init__(self):
        if (
            self.state != "verified"
            or self.service_ids != ("radarr", "sonarr")
            or len(self.instance_ids) != 2
            or any(type(value) is not int or value < 0 for value in self.instance_ids)
        ):
            raise SeerrArrWiringError("invalid_seerr_arr_wiring")


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError()
        result[key] = value
    return result


def _json(raw):
    try:
        return json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_unique,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
    except (UnicodeError, json.JSONDecodeError, ValueError, TypeError):
        raise SeerrArrWiringError("seerr_arr_protocol") from None


def _body(service):
    value = {
        "name": "Larenor " + service.service_id.title(),
        "hostname": service.hostname,
        "port": service.port,
        "apiKey": service.api_key,
        "useSsl": False,
        "baseUrl": "",
        "activeProfileId": service.profile_id,
        "activeProfileName": service.profile_name,
        "activeDirectory": service.root_path,
        "is4k": False,
        "isDefault": True,
        "externalUrl": "",
        "syncEnabled": True,
        "preventSearch": False,
    }
    if service.service_id == "radarr":
        value["minimumAvailability"] = "released"
    else:
        value["enableSeasonFolders"] = True
    return value


def _instance(service, value):
    expected = _body(service)
    if (
        type(value) is not dict
        or set(value) != {"id", *expected}
        or type(value.get("id")) is not int
        or not 0 <= value["id"] <= 2**31 - 1
        or any(type(value[key]) is not type(expected[key]) or value[key] != expected[key] for key in expected)
    ):
        raise SeerrArrWiringError("seerr_arr_conflict")
    return value["id"]


class SeerrArrWiring:
    @staticmethod
    def _exchange(connection, deadline, api_key, method, path, body=None):
        raw = None
        if body is not None:
            try:
                raw = json.dumps(
                    body,
                    ensure_ascii=False,
                    allow_nan=False,
                    separators=(",", ":"),
                ).encode("utf-8")
            except (ValueError, TypeError, UnicodeError):
                raise SeerrArrWiringError("invalid_seerr_arr_wiring") from None
            if len(raw) > 32768:
                raise SeerrArrWiringError("invalid_seerr_arr_wiring")
        connection.settimeout(_remaining(deadline))
        connection.sendall(
            _request_bytes(
                method,
                path,
                "seerr",
                {
                    "Accept": "application/json",
                    "X-Api-Key": api_key,
                    **({"Content-Type": "application/json"} if raw is not None else {}),
                },
                raw,
            )
        )
        status, response_body, closed = _response(
            _StartupReader(connection, deadline),
            524288,
            content_type="application/json",
            error_content_type="application/json",
        )
        return status, _json(response_body), closed

    @staticmethod
    def _discovery(service, value):
        if type(value) is not dict or set(value) != {"profiles", "rootFolders", "tags"}:
            raise SeerrArrWiringError("seerr_arr_selection_changed")
        profiles, roots, tags = value["profiles"], value["rootFolders"], value["tags"]
        if (
            type(profiles) is not list
            or type(roots) is not list
            or type(tags) is not list
            or len(profiles) > 128
            or len(roots) > 32
            or len(tags) > 256
        ):
            raise SeerrArrWiringError("seerr_arr_selection_changed")
        try:
            profile_matches = [
                item
                for item in profiles
                if type(item) is dict
                and set(item) == {"id", "name"}
                and type(item["id"]) is int
                and type(item["name"]) is str
                and item["id"] == service.profile_id
                and item["name"] == service.profile_name
            ]
            root_matches = [
                item
                for item in roots
                if type(item) is dict
                and set(item) == {"id", "path"}
                and type(item["id"]) is int
                and type(item["path"]) is str
                and item["path"] == service.root_path
            ]
            valid_profiles = all(
                type(item) is dict
                and set(item) == {"id", "name"}
                and type(item["id"]) is int
                and type(item["name"]) is str
                for item in profiles
            )
            valid_roots = all(
                type(item) is dict
                and set(item) == {"id", "path"}
                and type(item["id"]) is int
                and type(item["path"]) is str
                for item in roots
            )
        except (KeyError, TypeError, AttributeError):
            raise SeerrArrWiringError("seerr_arr_selection_changed") from None
        if not valid_profiles or not valid_roots or len(profile_matches) != 1 or len(root_matches) != 1:
            raise SeerrArrWiringError("seerr_arr_selection_changed")

    def configure(
        self,
        connection,
        *,
        seerr_api_key,
        services,
        total_seconds=60.0,
        close_connection=True,
    ):
        if (
            not _is_generated_key(seerr_api_key)
            or type(services) is not tuple
            or tuple(getattr(item, "service_id", None) for item in services)
            != ("radarr", "sonarr")
            or any(type(item) is not SeerrArrService for item in services)
            or type(total_seconds) not in (int, float)
            or not math.isfinite(total_seconds)
            or not 0 < total_seconds <= 120
            or type(close_connection) is not bool
            or any(
                not callable(getattr(connection, name, None))
                for name in ("sendall", "recv", "settimeout", "shutdown", "close")
            )
        ):
            raise SeerrArrWiringError("invalid_seerr_arr_wiring")
        deadline = time.monotonic() + total_seconds
        scope = None
        instance_ids = []
        uncertain = False
        try:
            scope = _Deadline(deadline)
            scope.attach(connection)
            for service in services:
                path = "/api/v1/settings/" + service.service_id
                status, existing, closed = self._exchange(
                    connection, deadline, seerr_api_key, "GET", path
                )
                if status in {401, 403}:
                    raise SeerrArrWiringError("seerr_arr_unavailable")
                if status != 200 or type(existing) is not list or len(existing) > 8:
                    raise SeerrArrWiringError("seerr_arr_protocol")
                if existing:
                    if len(existing) != 1:
                        raise SeerrArrWiringError("seerr_arr_conflict")
                    instance_ids.append(_instance(service, existing[0]))
                    if closed and service is not services[-1]:
                        raise SeerrArrWiringError("seerr_arr_protocol")
                    continue
                if closed:
                    raise SeerrArrWiringError("seerr_arr_protocol")
                test_body = {
                    "hostname": service.hostname,
                    "port": service.port,
                    "apiKey": service.api_key,
                    "useSsl": False,
                    "baseUrl": "",
                }
                status, discovered, closed = self._exchange(
                    connection,
                    deadline,
                    seerr_api_key,
                    "POST",
                    path + "/test",
                    test_body,
                )
                if status != 200:
                    raise SeerrArrWiringError("seerr_arr_selection_changed")
                self._discovery(service, discovered)
                if closed:
                    raise SeerrArrWiringError("seerr_arr_protocol")
                uncertain = True
                status, created, closed = self._exchange(
                    connection,
                    deadline,
                    seerr_api_key,
                    "POST",
                    path,
                    _body(service),
                )
                if status != 201:
                    raise SeerrArrWiringError(
                        "seerr_arr_protocol", uncertain_effect=True
                    )
                identifier = _instance(service, created)
                if closed:
                    raise SeerrArrWiringError(
                        "seerr_arr_protocol", uncertain_effect=True
                    )
                status, observed, closed = self._exchange(
                    connection, deadline, seerr_api_key, "GET", path
                )
                if (
                    status != 200
                    or type(observed) is not list
                    or len(observed) != 1
                    or _instance(service, observed[0]) != identifier
                ):
                    raise SeerrArrWiringError(
                        "seerr_arr_protocol", uncertain_effect=True
                    )
                instance_ids.append(identifier)
                uncertain = False
                if closed and service is not services[-1]:
                    raise SeerrArrWiringError("seerr_arr_protocol")
            return SeerrArrWiringResult(
                "verified", ("radarr", "sonarr"), tuple(instance_ids)
            )
        except SeerrArrWiringError:
            raise
        except (socket.timeout, TimeoutError):
            raise SeerrArrWiringError(
                "seerr_arr_timeout", uncertain_effect=uncertain
            ) from None
        except _ConnectionLost:
            raise SeerrArrWiringError(
                "seerr_arr_unavailable", uncertain_effect=uncertain
            ) from None
        except (ProbeTransportError, ValueError, TypeError, AttributeError, UnicodeError):
            raise SeerrArrWiringError(
                "seerr_arr_protocol", uncertain_effect=uncertain
            ) from None
        except (OSError, RuntimeError):
            raise SeerrArrWiringError(
                "seerr_arr_timeout" if time.monotonic() >= deadline else "seerr_arr_unavailable",
                uncertain_effect=uncertain,
            ) from None
        finally:
            if scope is not None:
                if not close_connection:
                    scope.timer.cancel()
                    with scope.lock:
                        scope.socket = None
                scope.finish()
