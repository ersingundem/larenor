"""Bounded, authority-bound Home Assistant entity history observations."""

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import re

from ..errors import ApiError
from ..home_resources.models import ActorFacts
from ..services.transport import ProbeTransportError, ServiceTransport
from ..vault import validate_json_bounds
from .read_only_websocket import (
    HomeAssistantReadOnlyWebSocket,
    HomeAssistantWebSocketError,
)


_ENTITY = re.compile(r"[a-z][a-z0-9_]{0,63}\.[a-z0-9_]{1,191}\Z")
_PLATFORM = re.compile(r"[a-z0-9_]{1,64}\Z")
_MAX_STATES = 256
_MAX_BYTES = 256 * 1024
_WINDOW_MS = 30 * 60 * 1000


def _canonical(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
        allow_nan=False,
    ).encode("ascii")


def _timestamp(value):
    if type(value) is not str or not 1 <= len(value) <= 40:
        raise ValueError
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError
    return round(parsed.astimezone(timezone.utc).timestamp() * 1000)


def _iso(value_ms):
    return datetime.fromtimestamp(value_ms / 1000, timezone.utc).isoformat(
        timespec="milliseconds"
    ).replace("+00:00", "Z")


def _json(response):
    def unique(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError
            result[key] = value
        return result

    types = [
        value.split(";", 1)[0].strip().lower()
        for name, value in response.headers if name.lower() == "content-type"
    ]
    if response.status != 200 or types != ["application/json"]:
        raise ValueError
    value = json.loads(
        response.body.decode("utf-8"), object_pairs_hook=unique,
        parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
    )
    validate_json_bounds(value)
    return value


@dataclass(frozen=True)
class HomeAssistantHistoryObservation:
    resource_id: str
    resource_revision: int
    binding_id: str
    binding_revision: int
    service_id: str
    service_revision: int
    entity_id: str
    registry_digest: str
    captured_at_ms: int
    starts_at_ms: int
    states: tuple[tuple[int, str], ...]
    history_digest: str

    def evidence(self):
        return {
            "provider": "home_assistant_history",
            "resourceId": self.resource_id,
            "resourceRevision": self.resource_revision,
            "bindingId": self.binding_id,
            "bindingRevision": self.binding_revision,
            "serviceId": self.service_id,
            "serviceRevision": self.service_revision,
            "entityId": self.entity_id,
            "registryDigest": self.registry_digest,
            "historyDigest": self.history_digest,
            "sampleCount": len(self.states),
            "startsAtMs": self.starts_at_ms,
            "capturedAtMs": self.captured_at_ms,
        }


class HomeAssistantStateHistoryObserver:
    """Read one recent entity history without exposing attributes or secrets."""

    def __init__(
        self, adapter_provider, clock, *, websocket_factory=None,
        transport_factory=None,
    ):
        self._adapter_provider = adapter_provider
        self._clock = clock
        self._websocket_factory = websocket_factory or HomeAssistantReadOnlyWebSocket
        self._transport_factory = transport_factory or ServiceTransport

    def _prepared(self, actor, resource_id):
        adapter = self._adapter_provider()
        scope = adapter.resources.scope
        with adapter._tx(
            actor, scope.coreId, scope.homeId, admin=True,
            consume_rate_limit=False,
        ) as (connection, facts):
            fingerprint, row, _ref, binding, service = adapter._facts(
                connection, facts, resource_id
            )
            if binding is None or _ENTITY.fullmatch(binding.entityId) is None:
                raise ApiError("ha_binding_changed", 409)
            service = adapter.services._authenticated_home_assistant_connection(
                connection, service.id, service.revision
            )
            resource_revision = row["revision"]

        def guard():
            adapter._fresh(
                actor, scope.coreId, scope.homeId, resource_id, fingerprint,
                None, lambda: False, admin=True, consume_rate_limit=False,
                authority_guard=lambda connection: (
                    adapter.services._authenticated_home_assistant_connection(
                        connection, service.id, service.revision
                    )
                ),
            )

        return binding, service, resource_revision, guard

    def assert_current_in(self, connection, actor, observation):
        adapter = self._adapter_provider()
        adapter.auth.assert_current(connection, actor)
        adapter.resources._check_context(
            connection, adapter.resources.scope.coreId,
            adapter.resources.scope.homeId,
        )
        adapter.resources._state(connection)
        account = connection.execute(
            "SELECT * FROM users WHERE id=?", (actor.id,)
        ).fetchone()
        if account is None:
            raise ApiError("invalid_session", 401)
        facts = ActorFacts(
            userId=account["id"], revision=account["revision"],
            role=account["role"], disabled=bool(account["disabled"]),
            mustChangePassword=bool(account["must_change_password"]),
            sessionCurrent=True,
        )
        _fingerprint, row, _ref, binding, service = adapter._facts(
            connection, facts, observation.resource_id
        )
        service = adapter.services._authenticated_home_assistant_connection(
            connection, service.id, service.revision
        )
        if (
            row["revision"] != observation.resource_revision
            or binding.id != observation.binding_id
            or binding.revision != observation.binding_revision
            or binding.entityId != observation.entity_id
            or service.id != observation.service_id
            or service.revision != observation.service_revision
        ):
            raise ApiError("ha_binding_changed", 409)

    @staticmethod
    def _registry_digest(entries, entity_id):
        matches = [item for item in entries if item.get("entity_id") == entity_id]
        if len(matches) != 1:
            raise ApiError("ha_binding_changed", 409)
        item = matches[0]
        unique_id, platform = item.get("unique_id"), item.get("platform")
        if (
            type(unique_id) is not str or not 1 <= len(unique_id) <= 256
            or any(ord(char) < 32 or ord(char) == 127 for char in unique_id)
            or type(platform) is not str or _PLATFORM.fullmatch(platform) is None
            or item.get("disabled_by") is not None
        ):
            raise ApiError("ha_binding_changed", 409)
        return hashlib.sha256(_canonical({
            "entityId": entity_id, "platform": platform, "uniqueId": unique_id,
        })).hexdigest()

    @staticmethod
    def _states(value, entity_id, starts_at_ms, captured_at_ms):
        if (
            not isinstance(value, list) or len(value) != 1
            or not isinstance(value[0], list) or len(value[0]) > _MAX_STATES
        ):
            raise ValueError
        result = []
        for item in value[0]:
            if not isinstance(item, dict) or item.get("entity_id") != entity_id:
                raise ValueError
            state = item.get("state")
            if (
                type(state) is not str or not 1 <= len(state) <= 255
                or any(ord(char) < 32 or ord(char) == 127 for char in state)
                or not isinstance(item.get("attributes"), dict)
            ):
                raise ValueError
            occurred = _timestamp(item.get("last_changed"))
            if (
                occurred > captured_at_ms + 30_000
                or occurred < starts_at_ms and result
            ):
                raise ValueError
            if result and occurred < result[-1][0]:
                raise ValueError
            if not result or result[-1] != (occurred, state):
                result.append((occurred, state))
        if not result:
            raise ApiError("server_unavailable", 503)
        return tuple(result)

    def observe(self, actor, resource_id):
        binding, service, resource_revision, guard = self._prepared(
            actor, resource_id
        )
        captured_at_ms = round(float(self._clock()) * 1000)
        starts_at_ms = max(0, captured_at_ms - _WINDOW_MS)
        try:
            with self._websocket_factory(service).session(
                timeout=8.0, before_io=guard, after_io=guard,
            ) as session:
                registry_digest = self._registry_digest(
                    session.list_entity_registry(), binding.entityId
                )
            headers = {
                "Authorization": "Bearer " + service.credentials["token"],
                "Accept": "application/json",
            }
            with self._transport_factory(
                service.base_url, timeout=8.0, max_bytes=_MAX_BYTES
            ) as transport:
                response = transport.request(
                    "GET", "/api/history/period/" + _iso(starts_at_ms),
                    headers=headers, before_send=guard,
                    query_parameters={
                        "filter_entity_id": binding.entityId,
                        "end_time": _iso(captured_at_ms),
                    },
                )
            guard()
            raw = _json(response)
            states = self._states(
                raw, binding.entityId, starts_at_ms, captured_at_ms
            )
            history_digest = hashlib.sha256(
                b"larenor-ha-history-v1\0" + _canonical(raw)
            ).hexdigest()
        except ApiError:
            raise
        except (
            HomeAssistantWebSocketError, ProbeTransportError, KeyError,
            TypeError, ValueError, UnicodeError, json.JSONDecodeError,
        ):
            raise ApiError("server_unavailable", 503) from None
        return HomeAssistantHistoryObservation(
            resource_id=resource_id,
            resource_revision=resource_revision,
            binding_id=binding.id,
            binding_revision=binding.revision,
            service_id=service.id,
            service_revision=service.revision,
            entity_id=binding.entityId,
            registry_digest=registry_digest,
            captured_at_ms=captured_at_ms,
            starts_at_ms=starts_at_ms,
            states=states,
            history_digest=history_digest,
        )
