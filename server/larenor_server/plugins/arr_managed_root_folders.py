"""Idempotent root-folder wiring for Larenor-owned Sonarr and Radarr."""

from dataclasses import dataclass
import json
import math
import socket
import time

from ..services.transport import (
    ProbeTransportError,
    _Deadline,
    _remaining,
    _request_bytes,
)
from .arr_owned_config import is_arr_api_key
from .jellyfin_startup import _ConnectionLost, _response, _StartupReader


_ROOTS = {"sonarr": "/data/shows", "radarr": "/data/movies"}
_CODES = frozenset(
    {
        "invalid_arr_managed_root_folders",
        "arr_root_folders_authentication_failed",
        "arr_root_folders_observation_protocol",
        "arr_root_folders_observation_framing",
        "arr_root_folders_observation_http",
        "arr_root_folders_observation_closed",
        "arr_root_folders_observation_payload",
        "arr_root_folder_create_protocol",
        "arr_root_folders_verification_protocol",
        "arr_root_folder_conflict",
        "arr_root_folders_unavailable",
        "arr_root_folders_timeout",
    }
)


class ArrManagedRootFoldersError(Exception):
    def __init__(
        self,
        code="arr_root_folders_unavailable",
        *,
        completed_steps=(),
        uncertain_effect=False,
    ):
        self.code = code if code in _CODES else "arr_root_folders_unavailable"
        self.completed_steps = tuple(completed_steps)
        self.uncertain_effect = uncertain_effect is True
        super().__init__(self.code)

    def __repr__(self):
        return (
            f"ArrManagedRootFoldersError({self.code!r}, "
            f"completed_steps={len(self.completed_steps)}, "
            f"uncertain_effect={self.uncertain_effect!r})"
        )


@dataclass(frozen=True)
class ArrManagedRootFoldersLimits:
    total_seconds: float = 30.0
    max_response_bytes: int = 262144

    def __post_init__(self):
        if (
            type(self.total_seconds) not in (int, float)
            or not math.isfinite(self.total_seconds)
            or not 0 < self.total_seconds <= 120
            or type(self.max_response_bytes) is not int
            or not 1 <= self.max_response_bytes <= 1048576
        ):
            raise ArrManagedRootFoldersError("invalid_arr_managed_root_folders")


@dataclass(frozen=True)
class ArrManagedRootFoldersResult:
    state: str
    service_id: str
    path: str
    completed_steps: tuple[str, ...]


def _unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError()
        value[key] = item
    return value


def _json(raw, code):
    try:
        return json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_unique,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
    except (UnicodeError, json.JSONDecodeError, ValueError, TypeError):
        raise ArrManagedRootFoldersError(code) from None


def _existing(value, desired):
    if type(value) is not list or len(value) > 16:
        raise ArrManagedRootFoldersError("arr_root_folder_conflict")
    if not value:
        return False
    if len(value) != 1 or type(value[0]) is not dict:
        raise ArrManagedRootFoldersError("arr_root_folder_conflict")
    item = value[0]
    identifier = item.get("id")
    if type(identifier) is not int or identifier <= 0 or item.get("path") != desired:
        raise ArrManagedRootFoldersError("arr_root_folder_conflict")
    return True


def _wire(method, service_id, api_key, body=None, *, final=False):
    headers = {"Accept": "application/json", "X-Api-Key": api_key}
    raw = None
    if body is not None:
        raw = json.dumps(body, sort_keys=True, separators=(",", ":")).encode("ascii")
        headers["Content-Type"] = "application/json"
    request = _request_bytes(method, "/api/v3/rootfolder", service_id, headers, raw)
    if not final:
        request = request.replace(
            b"Connection: close\r\n", b"Connection: keep-alive\r\n", 1
        )
    return request


class ArrManagedRootFolders:
    def apply(
        self,
        connection,
        *,
        service_id,
        api_key,
        limits=ArrManagedRootFoldersLimits(),
    ):
        if (
            service_id not in _ROOTS
            or not is_arr_api_key(api_key)
            or type(limits) is not ArrManagedRootFoldersLimits
            or any(
                not callable(getattr(connection, name, None))
                for name in ("sendall", "recv", "settimeout", "shutdown", "close")
            )
        ):
            raise ArrManagedRootFoldersError("invalid_arr_managed_root_folders")
        try:
            limits = ArrManagedRootFoldersLimits(**vars(limits))
        except (ValueError, TypeError, AttributeError, ArrManagedRootFoldersError):
            raise ArrManagedRootFoldersError(
                "invalid_arr_managed_root_folders"
            ) from None

        desired = _ROOTS[service_id]
        deadline = time.monotonic() + limits.total_seconds
        completed = []
        mutation_sent = False
        protocol_code = "arr_root_folders_observation_protocol"
        scope = None
        try:
            scope = _Deadline(deadline)
            scope.attach(connection)
            reader = _StartupReader(connection, deadline)
            try:
                status, raw, closes = self._get(
                    connection,
                    reader,
                    deadline,
                    limits,
                    service_id,
                    api_key,
                    final=False,
                )
            except ProbeTransportError:
                raise ArrManagedRootFoldersError(
                    "arr_root_folders_observation_framing"
                ) from None
            self._status(status, "arr_root_folders_observation_http")
            if closes:
                raise ArrManagedRootFoldersError("arr_root_folders_observation_closed")
            completed.append("root_folders_observed")
            if _existing(_json(raw, "arr_root_folders_observation_payload"), desired):
                completed.append("root_folder_verified")
                return ArrManagedRootFoldersResult(
                    "verified", service_id, desired, tuple(completed)
                )

            protocol_code = "arr_root_folder_create_protocol"
            mutation_sent = True
            status, raw, closes = self._post(
                connection, reader, deadline, limits, service_id, api_key, desired
            )
            if status in {401, 403}:
                raise ArrManagedRootFoldersError(
                    "arr_root_folders_authentication_failed"
                )
            if status != 201 or closes:
                raise ArrManagedRootFoldersError(protocol_code)
            created = _json(raw, protocol_code)
            if (
                type(created) is not dict
                or type(created.get("id")) is not int
                or created["id"] <= 0
                or created.get("path") != desired
            ):
                raise ArrManagedRootFoldersError(protocol_code)
            completed.append("root_folder_created")

            protocol_code = "arr_root_folders_verification_protocol"
            status, raw, _closes = self._get(
                connection,
                reader,
                deadline,
                limits,
                service_id,
                api_key,
                final=True,
            )
            self._status(status, protocol_code)
            if not _existing(_json(raw, protocol_code), desired):
                raise ArrManagedRootFoldersError("arr_root_folder_conflict")
            completed.append("root_folder_verified")
            return ArrManagedRootFoldersResult(
                "verified", service_id, desired, tuple(completed)
            )
        except ArrManagedRootFoldersError as error:
            if error.completed_steps or error.uncertain_effect:
                raise
            raise ArrManagedRootFoldersError(
                error.code,
                completed_steps=completed,
                uncertain_effect=mutation_sent,
            ) from None
        except (socket.timeout, TimeoutError):
            raise ArrManagedRootFoldersError(
                "arr_root_folders_timeout",
                completed_steps=completed,
                uncertain_effect=mutation_sent,
            ) from None
        except _ConnectionLost:
            raise ArrManagedRootFoldersError(
                "arr_root_folders_unavailable",
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
                "arr_root_folders_timeout"
                if time.monotonic() >= deadline
                else protocol_code
            )
            raise ArrManagedRootFoldersError(
                code,
                completed_steps=completed,
                uncertain_effect=mutation_sent,
            ) from None
        except (OSError, RuntimeError):
            code = (
                "arr_root_folders_timeout"
                if time.monotonic() >= deadline
                else "arr_root_folders_unavailable"
            )
            raise ArrManagedRootFoldersError(
                code,
                completed_steps=completed,
                uncertain_effect=mutation_sent,
            ) from None
        finally:
            if scope is not None:
                scope.finish()

    @staticmethod
    def _status(status, protocol_code):
        if status in {401, 403}:
            raise ArrManagedRootFoldersError("arr_root_folders_authentication_failed")
        if status != 200:
            raise ArrManagedRootFoldersError(protocol_code)

    @staticmethod
    def _get(connection, reader, deadline, limits, service_id, api_key, *, final):
        connection.settimeout(_remaining(deadline))
        connection.sendall(_wire("GET", service_id, api_key, final=final))
        return _response(
            reader,
            limits.max_response_bytes,
            content_type="application/json",
            error_content_type="text/plain",
        )

    @staticmethod
    def _post(connection, reader, deadline, limits, service_id, api_key, path):
        connection.settimeout(_remaining(deadline))
        connection.sendall(
            _wire("POST", service_id, api_key, {"path": path}, final=False)
        )
        return _response(
            reader,
            limits.max_response_bytes,
            content_type="application/json",
            error_content_type="text/plain",
        )
