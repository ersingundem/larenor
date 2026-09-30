import base64
import hashlib
import json
import re
from datetime import datetime
from types import MappingProxyType

from ..services.service import ServiceConnection
from ..services.transport import ProbeResponse, ProbeTransportError, ServiceTransport
from .models import (
    MemoryAsset,
    MemoryError,
    MemoryPolicy,
    MemorySearch,
    MemorySearchResult,
    _uuid,
)

_MAX_RESPONSE = 2 * 1024 * 1024
_MAX_FILENAME = 512
_MAX_THUMBHASH = 1024


def compatible_version(value):
    """Structured album-confined search is verified against Immich 3.2.x."""
    return type(value) is str and re.fullmatch(r"v?3\.2\.(0|[1-9][0-9]{0,5})", value) is not None


def _verify_version(transport, headers):
    # Probe the actual peer for every operation: saved verification can predate
    # an upstream downgrade that would silently ignore structured filters.
    value = _json_response(transport.request("GET", "/api/server/about", headers=headers))
    if type(value) is not dict or not compatible_version(value.get("version")):
        raise MemoryError("unsupported_version")


def _json_response(response):
    if response.status in {401, 403}:
        raise MemoryError("binding_changed")
    if (response.status != 200 or type(response.body) is not bytes
            or len(response.body) > _MAX_RESPONSE
            or [value.split(";", 1)[0].strip().lower()
                for key, value in response.headers
                if key.lower() == "content-type"] != ["application/json"]):
        raise MemoryError("invalid_response")
    def pairs(values):
        result = {}
        for key, value in values:
            if key in result:
                raise ValueError()
            result[key] = value
        return result
    try:
        return json.loads(response.body, object_pairs_hook=pairs,
                          parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()))
    except (ValueError, UnicodeError):
        raise MemoryError("invalid_response") from None


def _albums(response):
    values = _json_response(response)
    if (type(values) is not list or len(values) > 512
            or any(type(value) is not dict or not _uuid(value.get("id"))
                   or type(value.get("albumName")) is not str
                   or not 1 <= len(value["albumName"]) <= 256
                   or any(ord(char) < 32 or ord(char) == 127
                          for char in value["albumName"]) for value in values)
            or len({value["id"] for value in values}) != len(values)):
        raise MemoryError("invalid_response")
    return tuple({"albumId": value["id"], "title": value["albumName"]}
                 for value in values)


class ImmichAlbumCatalog:
    """Admin-only upstream catalogue reader; no original assets or writes."""

    def __init__(self, connection, *, transport_factory=ServiceTransport):
        keys = set(connection.credentials)
        if connection.kind != "immich" or keys not in ({"apiKey"}, {"token"}):
            raise MemoryError("binding_changed")
        credential = connection.credentials[next(iter(keys))]
        if (type(credential) is not str or not 1 <= len(credential) <= 2048
                or any(ord(char) < 32 or ord(char) == 127 for char in credential)):
            raise MemoryError("binding_changed")
        self._headers = {"Accept": "application/json",
            "x-api-key" if "apiKey" in keys else "Authorization":
            credential if "apiKey" in keys else "Bearer " + credential}
        try:
            self._transport = transport_factory(connection.base_url, max_bytes=_MAX_RESPONSE)
        except (ProbeTransportError, TypeError, ValueError):
            raise MemoryError("service_unavailable") from None

    def albums(self):
        try:
            _verify_version(self._transport, self._headers)
            return _albums(self._transport.request("GET", "/api/albums", headers=self._headers))
        except ProbeTransportError:
            raise MemoryError("service_unavailable") from None

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self._transport.close()


class ImmichMemoryAdapter:
    """Album-confined, metadata-minimizing Immich smart-search adapter."""

    def __init__(
        self,
        connection: ServiceConnection,
        policy: MemoryPolicy,
        *,
        transport_factory=ServiceTransport,
    ):
        keys = set(connection.credentials)
        if (
            connection.kind != "immich"
            or connection.id != policy.service_id
            or connection.revision != policy.service_revision
            or keys not in ({"apiKey"}, {"token"})
            or not callable(transport_factory)
        ):
            raise MemoryError("binding_changed")
        credential = connection.credentials[next(iter(keys))]
        if (type(credential) is not str or not 1 <= len(credential) <= 2048
                or any(ord(char) < 32 or ord(char) == 127 for char in credential)):
            raise MemoryError("binding_changed")
        self._policy = policy
        self._headers = MappingProxyType(
            {
                "Accept": "application/json",
                "Content-Type": "application/json",
                "x-api-key" if "apiKey" in keys else "Authorization": (
                    credential if "apiKey" in keys else f"Bearer {credential}"
                ),
            }
        )
        try:
            self._transport = transport_factory(
                connection.base_url, max_bytes=_MAX_RESPONSE
            )
        except (ProbeTransportError, TypeError, ValueError):
            raise MemoryError("service_unavailable") from None
        self._closed = False

    def search(self, request: MemorySearch) -> MemorySearchResult:
        if self._closed:
            raise MemoryError("retired")
        if not set(request.album_ids).issubset(self._policy.allowed_album_ids):
            raise MemoryError("album_forbidden")
        if request.person_ids and not self._policy.face_search_enabled:
            raise MemoryError("face_consent_required")
        body = {
            "query": request.query,
            "language": request.language,
            "size": request.limit,
            "filter": {
                "albumIds": {"any": []},
                "type": {"eq": "IMAGE"},
            },
        }
        if request.person_ids:
            body["filter"]["personIds"] = {"any": list(request.person_ids)}
        taken = {}
        if request.taken_after is not None:
            taken["gte"] = request.taken_after
        if request.taken_before is not None:
            taken["lt"] = request.taken_before
        if taken:
            body["filter"]["takenAt"] = taken
        try:
            _verify_version(self._transport, self._headers)
            per_album = []
            for album_id in request.album_ids:
                body["filter"]["albumIds"]["any"] = [album_id]
                encoded = json.dumps(
                    body, ensure_ascii=False, sort_keys=True, separators=(",", ":")
                ).encode("utf-8")
                if len(encoded) > 16384:
                    raise MemoryError("invalid_search")
                response = self._transport.request(
                    "POST", "/api/search/smart", headers=self._headers, body=encoded
                )
                per_album.append(self._parse(
                    response, request.limit, album_id).assets)
        except ProbeTransportError as error:
            code = (
                "service_unavailable" if error.code != "request_timeout" else "timeout"
            )
            raise MemoryError(code) from None
        assets = []
        seen = set()
        for rank in range(request.limit):
            for values in per_album:
                if rank >= len(values) or values[rank].id in seen:
                    continue
                seen.add(values[rank].id)
                assets.append(values[rank])
                if len(assets) == request.limit:
                    return MemorySearchResult(tuple(assets))
        return MemorySearchResult(tuple(assets))

    def asset(self, asset_id: str, *, source_album_id: str) -> MemoryAsset | None:
        """Read one source asset for integrity reconciliation; never downloads it."""
        if self._closed:
            raise MemoryError("retired")
        if not _uuid(asset_id) or not _uuid(source_album_id):
            raise MemoryError("invalid_search")
        if source_album_id not in self._policy.allowed_album_ids:
            raise MemoryError("album_forbidden")
        try:
            _verify_version(self._transport, self._headers)
            albums = _albums(self._transport.request(
                "GET", "/api/albums", headers=self._headers,
                query_parameters={"assetId": asset_id}))
            if source_album_id not in {value["albumId"] for value in albums}:
                return None
            response = self._transport.request(
                "GET", f"/api/assets/{asset_id}", headers=self._headers,
            )
        except ProbeTransportError as error:
            raise MemoryError(
                "timeout" if error.code == "request_timeout"
                else "service_unavailable"
            ) from None
        if response.status == 404:
            return None
        asset = self._asset(_json_response(response), source_album_id)
        if asset.id != asset_id:
            raise MemoryError("invalid_response")
        return asset

    @staticmethod
    def _parse(
        response: ProbeResponse, limit: int, source_album_id: str
    ) -> MemorySearchResult:
        if (
            not isinstance(response, ProbeResponse)
            or response.status != 200
            or not isinstance(response.body, bytes)
        ):
            raise MemoryError("invalid_response")
        content_types = [
            value.split(";", 1)[0].strip().lower()
            for key, value in response.headers
            if key.lower() == "content-type"
        ]
        if content_types != ["application/json"] or len(response.body) > _MAX_RESPONSE:
            raise MemoryError("invalid_response")
        try:
            value = _json_response(response)
            items = value["assets"]["items"]
        except (UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError):
            raise MemoryError("invalid_response") from None
        if (
            not isinstance(value, dict)
            or not isinstance(value.get("assets"), dict)
            or not isinstance(items, list)
            or len(items) > limit
        ):
            raise MemoryError("invalid_response")
        assets = tuple(
            ImmichMemoryAdapter._asset(item, source_album_id) for item in items
        )
        if len({asset.id for asset in assets}) != len(assets):
            raise MemoryError("invalid_response")
        return MemorySearchResult(assets)

    @staticmethod
    def _asset(value: object, source_album_id: str | None = None) -> MemoryAsset:
        if (
            not isinstance(value, dict)
            or not _uuid(value.get("id"))
            or value.get("type") != "IMAGE"
        ):
            raise MemoryError("invalid_response")
        name, taken, thumbhash, checksum = (
            value.get("originalFileName"),
            value.get("fileCreatedAt"),
            value.get("thumbhash"),
            value.get("checksum"),
        )
        if (
            not isinstance(name, str)
            or not 1 <= len(name) <= _MAX_FILENAME
            or any(ord(char) < 32 or ord(char) == 127 for char in name)
            or not isinstance(taken, str)
            or len(taken) > 40
            or thumbhash is not None
            and (not isinstance(thumbhash, str) or len(thumbhash) > _MAX_THUMBHASH)
            or not isinstance(checksum, str)
            or not 1 <= len(checksum) <= 512
        ):
            raise MemoryError("invalid_response")
        try:
            parsed = datetime.fromisoformat(taken.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                raise ValueError
            if thumbhash is not None:
                base64.b64decode(thumbhash, validate=True)
        except (ValueError, TypeError):
            raise MemoryError("invalid_response") from None
        return MemoryAsset(
            value["id"], name, taken, thumbhash,
            hashlib.sha256(checksum.encode("utf-8")).hexdigest(),
            source_album_id,
        )

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._transport.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
