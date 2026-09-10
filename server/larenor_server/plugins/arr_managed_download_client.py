"""Idempotent qBittorrent download-client wiring for owned Arr services."""

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
from .qbittorrent_api_key import is_qbittorrent_api_key


_CODES = frozenset({
    "invalid_arr_managed_download_client",
    "arr_download_client_authentication_failed",
    "arr_download_client_observation_protocol",
    "arr_download_client_observation_framing",
    "arr_download_client_observation_payload",
    "arr_download_client_schema_protocol",
    "arr_download_client_schema_conflict",
    "arr_download_client_test_protocol",
    "arr_download_client_test_failed",
    "arr_download_client_create_protocol",
    "arr_download_client_verification_protocol",
    "arr_download_client_conflict",
    "arr_download_client_unavailable",
    "arr_download_client_timeout",
})
_SERVICE_FIELDS = {
    "sonarr": ("tvCategory", "tvImportedCategory", "recentTvPriority", "olderTvPriority", "tv"),
    "radarr": ("movieCategory", "movieImportedCategory", "recentMoviePriority", "olderMoviePriority", "movies"),
}
_COMMON_FIELDS = (
    "host", "port", "useSsl", "urlBase", "apiKey", "username", "password",
    "initialState", "sequentialOrder", "firstAndLast", "contentLayout",
)


class ArrManagedDownloadClientError(Exception):
    def __init__(self, code="arr_download_client_unavailable", *,
                 completed_steps=(), uncertain_effect=False):
        self.code = code if code in _CODES else "arr_download_client_unavailable"
        self.completed_steps = tuple(completed_steps)
        self.uncertain_effect = uncertain_effect is True
        super().__init__(self.code)

    def __repr__(self):
        return (
            f"ArrManagedDownloadClientError({self.code!r}, "
            f"completed_steps={len(self.completed_steps)}, "
            f"uncertain_effect={self.uncertain_effect!r})"
        )


@dataclass(frozen=True)
class ArrManagedDownloadClientLimits:
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
            raise ArrManagedDownloadClientError(
                "invalid_arr_managed_download_client"
            )


@dataclass(frozen=True, repr=False)
class ArrManagedDownloadClientResult:
    state: str
    service_id: str
    client_id: int
    category: str
    completed_steps: tuple[str, ...]

    def __post_init__(self):
        if (
            self.state != "verified"
            or self.service_id not in _SERVICE_FIELDS
            or type(self.client_id) is not int
            or self.client_id <= 0
            or self.category != _SERVICE_FIELDS[self.service_id][4]
            or type(self.completed_steps) is not tuple
        ):
            raise ArrManagedDownloadClientError(
                "invalid_arr_managed_download_client"
            )

    def __repr__(self):
        return (
            "ArrManagedDownloadClientResult("
            f"state={self.state!r}, service_id={self.service_id!r}, "
            f"client_id={self.client_id!r}, category={self.category!r}, "
            f"completed_steps={len(self.completed_steps)})"
        )


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
        raise ArrManagedDownloadClientError(code) from None


def _field_names(service_id):
    category, imported, recent, older, _value = _SERVICE_FIELDS[service_id]
    return frozenset(_COMMON_FIELDS + (category, imported, recent, older))


def _field_values(service_id, qbittorrent_api_key):
    category, imported, recent, older, category_value = _SERVICE_FIELDS[service_id]
    return {
        "host": "qbittorrent",
        "port": 8080,
        "useSsl": False,
        "urlBase": "",
        "apiKey": qbittorrent_api_key,
        "username": "",
        "password": "",
        category: category_value,
        imported: "",
        recent: 0,
        older: 0,
        "initialState": 0,
        "sequentialOrder": False,
        "firstAndLast": False,
        "contentLayout": 0,
    }


def _fields(value, code):
    if type(value) is not list or len(value) > 32:
        raise ArrManagedDownloadClientError(code)
    result = {}
    for item in value:
        if type(item) is not dict or type(item.get("name")) is not str:
            raise ArrManagedDownloadClientError(code)
        name = item["name"]
        if name in result or "value" not in item:
            raise ArrManagedDownloadClientError(code)
        result[name] = item["value"]
    return result


def _schema_payload(value, service_id, qbittorrent_api_key):
    if type(value) is not list or len(value) > 32:
        raise ArrManagedDownloadClientError("arr_download_client_schema_conflict")
    matches = [item for item in value if type(item) is dict
               and item.get("implementation") == "QBittorrent"
               and item.get("configContract") == "QBittorrentSettings"
               and item.get("protocol") == "torrent"]
    if len(matches) != 1:
        raise ArrManagedDownloadClientError("arr_download_client_schema_conflict")
    if frozenset(_fields(
        matches[0].get("fields"), "arr_download_client_schema_conflict"
    )) != _field_names(service_id):
        raise ArrManagedDownloadClientError("arr_download_client_schema_conflict")
    return _desired(service_id, qbittorrent_api_key)


def _desired(service_id, qbittorrent_api_key):
    return {
        "name": "Larenor qBittorrent",
        "implementation": "QBittorrent",
        "configContract": "QBittorrentSettings",
        "enable": True,
        "protocol": "torrent",
        "priority": 1,
        "removeCompletedDownloads": True,
        "removeFailedDownloads": True,
        "tags": [],
        "fields": [
            {"name": name, "value": value}
            for name, value in _field_values(
                service_id, qbittorrent_api_key
            ).items()
        ],
    }


def _existing(value, service_id, qbittorrent_api_key):
    if type(value) is not list or len(value) > 8:
        raise ArrManagedDownloadClientError("arr_download_client_conflict")
    if not value:
        return None
    if len(value) != 1 or type(value[0]) is not dict:
        raise ArrManagedDownloadClientError("arr_download_client_conflict")
    item = value[0]
    identifier = item.get("id")
    desired = _desired(service_id, qbittorrent_api_key)
    for key in (
        "name", "implementation", "configContract", "enable", "protocol",
        "priority", "removeCompletedDownloads", "removeFailedDownloads", "tags",
    ):
        if item.get(key) != desired[key]:
            raise ArrManagedDownloadClientError("arr_download_client_conflict")
    if type(identifier) is not int or identifier <= 0:
        raise ArrManagedDownloadClientError("arr_download_client_conflict")
    observed = _fields(item.get("fields"), "arr_download_client_conflict")
    expected = _field_values(service_id, qbittorrent_api_key)
    if frozenset(observed) != frozenset(expected):
        raise ArrManagedDownloadClientError("arr_download_client_conflict")
    for name, expected_value in expected.items():
        value = observed[name]
        if name == "apiKey" and value == "********":
            continue
        if type(value) is not type(expected_value) or value != expected_value:
            raise ArrManagedDownloadClientError("arr_download_client_conflict")
    return identifier


def _wire(method, service_id, arr_api_key, target, body=None, *, final=False):
    headers = {"Accept": "application/json", "X-Api-Key": arr_api_key}
    raw = None
    if body is not None:
        raw = json.dumps(body, sort_keys=True, separators=(",", ":")).encode("ascii")
        headers["Content-Type"] = "application/json"
    request = _request_bytes(method, target, service_id, headers, raw)
    if not final:
        request = request.replace(
            b"Connection: close\r\n", b"Connection: keep-alive\r\n", 1
        )
    return request


class ArrManagedDownloadClient:
    def apply(self, connection, *, service_id, arr_api_key,
              qbittorrent_api_key,
              limits=ArrManagedDownloadClientLimits()):
        if (
            service_id not in _SERVICE_FIELDS
            or not is_arr_api_key(arr_api_key)
            or not is_qbittorrent_api_key(qbittorrent_api_key)
            or type(limits) is not ArrManagedDownloadClientLimits
            or any(not callable(getattr(connection, name, None)) for name in (
                "sendall", "recv", "settimeout", "shutdown", "close"
            ))
        ):
            raise ArrManagedDownloadClientError(
                "invalid_arr_managed_download_client"
            )
        try:
            limits = ArrManagedDownloadClientLimits(**vars(limits))
        except (ValueError, TypeError, AttributeError,
                ArrManagedDownloadClientError):
            raise ArrManagedDownloadClientError(
                "invalid_arr_managed_download_client"
            ) from None

        deadline = time.monotonic() + limits.total_seconds
        completed = []
        mutation_sent = False
        protocol_code = "arr_download_client_observation_protocol"
        scope = None
        try:
            scope = _Deadline(deadline)
            scope.attach(connection)
            reader = _StartupReader(connection, deadline)
            status, raw, closes = self._request(
                connection, reader, deadline, limits, "GET", service_id,
                arr_api_key, "/api/v3/downloadclient"
            )
            self._status(status, protocol_code)
            if closes:
                raise ArrManagedDownloadClientError(
                    "arr_download_client_observation_protocol"
                )
            observed = _json(raw, "arr_download_client_observation_payload")
            completed.append("download_clients_observed")
            existing_id = _existing(
                observed, service_id, qbittorrent_api_key
            )

            protocol_code = "arr_download_client_schema_protocol"
            status, raw, closes = self._request(
                connection, reader, deadline, limits, "GET", service_id,
                arr_api_key, "/api/v3/downloadclient/schema"
            )
            self._status(status, protocol_code)
            if closes:
                raise ArrManagedDownloadClientError(protocol_code)
            payload = _schema_payload(
                _json(raw, protocol_code), service_id, qbittorrent_api_key
            )
            completed.append("schema_verified")

            protocol_code = "arr_download_client_test_protocol"
            status, raw, closes = self._request(
                connection, reader, deadline, limits, "POST", service_id,
                arr_api_key, "/api/v3/downloadclient/test", payload
            )
            if status in {401, 403}:
                raise ArrManagedDownloadClientError(
                    "arr_download_client_authentication_failed"
                )
            if status != 200 or closes or _json(raw, protocol_code) != {}:
                raise ArrManagedDownloadClientError(
                    "arr_download_client_test_failed"
                )
            completed.append("connection_tested")

            if existing_id is None:
                protocol_code = "arr_download_client_create_protocol"
                mutation_sent = True
                status, raw, closes = self._request(
                    connection, reader, deadline, limits, "POST", service_id,
                    arr_api_key, "/api/v3/downloadclient", payload
                )
                if status in {401, 403}:
                    raise ArrManagedDownloadClientError(
                        "arr_download_client_authentication_failed"
                    )
                if status != 201 or closes:
                    raise ArrManagedDownloadClientError(protocol_code)
                created = _json(raw, protocol_code)
                created_id = created.get("id") if type(created) is dict else None
                if type(created_id) is not int or created_id <= 0:
                    raise ArrManagedDownloadClientError(protocol_code)
                completed.append("download_client_created")

            protocol_code = "arr_download_client_verification_protocol"
            status, raw, _closes = self._request(
                connection, reader, deadline, limits, "GET", service_id,
                arr_api_key, "/api/v3/downloadclient", final=True
            )
            self._status(status, protocol_code)
            verified_id = _existing(
                _json(raw, protocol_code), service_id, qbittorrent_api_key
            )
            if verified_id is None or (
                existing_id is not None and verified_id != existing_id
            ):
                raise ArrManagedDownloadClientError(
                    "arr_download_client_conflict"
                )
            completed.append("download_client_verified")
            return ArrManagedDownloadClientResult(
                "verified", service_id, verified_id,
                _SERVICE_FIELDS[service_id][4], tuple(completed)
            )
        except ArrManagedDownloadClientError as error:
            if error.completed_steps or error.uncertain_effect:
                raise
            raise ArrManagedDownloadClientError(
                error.code, completed_steps=completed,
                uncertain_effect=mutation_sent
            ) from None
        except (socket.timeout, TimeoutError):
            raise ArrManagedDownloadClientError(
                "arr_download_client_timeout", completed_steps=completed,
                uncertain_effect=mutation_sent
            ) from None
        except _ConnectionLost:
            raise ArrManagedDownloadClientError(
                "arr_download_client_unavailable", completed_steps=completed,
                uncertain_effect=mutation_sent
            ) from None
        except (ProbeTransportError, ValueError, TypeError, AttributeError,
                UnicodeError, json.JSONDecodeError):
            code = ("arr_download_client_timeout"
                    if time.monotonic() >= deadline else protocol_code)
            raise ArrManagedDownloadClientError(
                code, completed_steps=completed,
                uncertain_effect=mutation_sent
            ) from None
        except (OSError, RuntimeError):
            code = ("arr_download_client_timeout"
                    if time.monotonic() >= deadline
                    else "arr_download_client_unavailable")
            raise ArrManagedDownloadClientError(
                code, completed_steps=completed,
                uncertain_effect=mutation_sent
            ) from None
        finally:
            if scope is not None:
                scope.finish()

    @staticmethod
    def _status(status, code):
        if status in {401, 403}:
            raise ArrManagedDownloadClientError(
                "arr_download_client_authentication_failed"
            )
        if status != 200:
            raise ArrManagedDownloadClientError(code)

    @staticmethod
    def _request(connection, reader, deadline, limits, method, service_id,
                 arr_api_key, target, body=None, *, final=False):
        connection.settimeout(_remaining(deadline))
        connection.sendall(_wire(
            method, service_id, arr_api_key, target, body, final=final
        ))
        return _response(
            reader, limits.max_response_bytes,
            content_type="application/json", error_content_type="text/plain"
        )
