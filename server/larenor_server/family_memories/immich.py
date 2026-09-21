import base64
import json
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
        if not isinstance(credential, str) or not credential or len(credential) > 2048:
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
                "albumIds": {"any": list(request.album_ids)},
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
        encoded = json.dumps(
            body, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        if len(encoded) > 16384:
            raise MemoryError("invalid_search")
        try:
            response = self._transport.request(
                "POST", "/api/search/smart", headers=self._headers, body=encoded
            )
        except ProbeTransportError as error:
            code = (
                "service_unavailable" if error.code != "request_timeout" else "timeout"
            )
            raise MemoryError(code) from None
        return self._parse(response, request.limit)

    @staticmethod
    def _parse(response: ProbeResponse, limit: int) -> MemorySearchResult:
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
            value = json.loads(response.body)
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
        assets = tuple(ImmichMemoryAdapter._asset(item) for item in items)
        if len({asset.id for asset in assets}) != len(assets):
            raise MemoryError("invalid_response")
        return MemorySearchResult(assets)

    @staticmethod
    def _asset(value: object) -> MemoryAsset:
        if (
            not isinstance(value, dict)
            or not _uuid(value.get("id"))
            or value.get("type") != "IMAGE"
        ):
            raise MemoryError("invalid_response")
        name, taken, thumbhash = (
            value.get("originalFileName"),
            value.get("fileCreatedAt"),
            value.get("thumbhash"),
        )
        if (
            not isinstance(name, str)
            or not 1 <= len(name) <= _MAX_FILENAME
            or any(ord(char) < 32 or ord(char) == 127 for char in name)
            or not isinstance(taken, str)
            or len(taken) > 40
            or thumbhash is not None
            and (not isinstance(thumbhash, str) or len(thumbhash) > _MAX_THUMBHASH)
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
        return MemoryAsset(value["id"], name, taken, thumbhash)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._transport.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
