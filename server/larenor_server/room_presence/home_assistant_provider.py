"""Authenticated Home Assistant MQTT-room discovery and observation adapter."""

from datetime import datetime, timezone
import hashlib
import hmac
import json
import math

from ..errors import ApiError
from ..home_assistant.read_only_websocket import (
    HomeAssistantReadOnlyWebSocket,
    HomeAssistantWebSocketError,
)
from ..services.transport import ProbeTransportError, ServiceTransport
from ..vault import validate_json_bounds
from .provider_models import MqttRoomEntityCandidate
from .provider_source import VerifiedMqttRoomEntity


MAX_ENTITIES = 4096
MAX_STATE_BYTES = 65_536
MAX_SAFE_INTEGER = 2**53 - 1
_UNAVAILABLE = {"unknown", "unavailable", "not_home"}


class HomeAssistantMqttRoomProvider:
    def __init__(
        self, db, auth, services, home_resources, context,
        connection_resolver, room_resolver, *, clock, candidate_key,
        websocket_factory=None, transport_factory=None,
    ):
        self._db, self._auth, self._services = db, auth, services
        self._home_resources, self._context = home_resources, context
        self._connection = connection_resolver
        self._room = room_resolver
        self._clock = clock
        self._candidate_key = candidate_key
        self._websocket = websocket_factory or HomeAssistantReadOnlyWebSocket
        self._transport = transport_factory or ServiceTransport

    def now_ms(self):
        return int(self._clock() * 1000)

    def _candidate_id(self, service, entity, unique_id):
        return hmac.new(
            self._candidate_key,
            json.dumps(
                [service.id, service.revision, entity, unique_id],
                separators=(",", ":"),
            ).encode(),
            hashlib.sha256,
        ).hexdigest()

    def setup(self, actor):
        services = [
            item for item in self._services().list(actor)["services"]
            if item["kind"] == "home_assistant"
            and item["verification"]["state"] == "authenticated"
            and item["credentialKeys"] == ["token"]
        ]
        resources = self._home_resources.list(
            actor, self._context.coreId, self._context.homeId, limit=100
        )
        if resources["nextAfter"] is not None:
            raise ApiError("presence_provider_limit", 429)
        return {
            "schemaVersion": 1,
            "services": services,
            "rooms": [
                item for item in resources["entries"]
                if item["ref"]["kind"] == "room"
            ],
            "provider": "home_assistant_mqtt_room",
            "advisoryOnly": True,
            "grantsAccess": False,
        }

    def _selected(self, actor, service_id, revision):
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            self._auth.assert_current(connection, actor)
            return self._connection(connection, service_id, revision)

    def _registry(self, service, current):
        try:
            with self._websocket(service).session(
                timeout=8.0, before_io=current, after_io=current
            ) as session:
                rows = session.list_entity_registry()
        except ApiError:
            raise
        except HomeAssistantWebSocketError:
            raise ApiError("presence_provider_unavailable", 503) from None
        current()
        if len(rows) > MAX_ENTITIES:
            raise ApiError("presence_provider_limit", 429)
        values = {}
        for row in rows:
            entity = row.get("entity_id")
            unique_id = row.get("unique_id")
            if (
                not isinstance(entity, str)
                or not entity.startswith("sensor.")
                or len(entity) > 128
                or row.get("platform") != "mqtt_room"
                or not isinstance(unique_id, str)
                or not unique_id.strip()
                or len(unique_id) > 255
                or row.get("disabled_by") is not None
                or row.get("hidden_by") is not None
            ):
                continue
            if entity in values:
                raise ApiError("presence_provider_unavailable", 503)
            name = row.get("name") or row.get("original_name") or entity
            if (
                not isinstance(name, str) or not name.strip() or len(name) > 80
                or any(ord(char) < 32 or ord(char) == 127 for char in name)
            ):
                name = entity
            values[entity] = (
                MqttRoomEntityCandidate(
                    schemaVersion=1,
                    candidateId=self._candidate_id(
                        service, entity, unique_id.strip()
                    ),
                    entityId=entity,
                    name=name.strip(), platform="mqtt_room",
                ),
                unique_id.strip(),
            )
        return values

    def entities(self, actor, service_id, revision):
        service = self._selected(actor, service_id, revision)

        def current():
            if self._selected(actor, service.id, service.revision) != service:
                raise ApiError("revision_conflict", 409)

        values = self._registry(service, current)
        return {
            "schemaVersion": 1,
            "entities": [
                value[0].model_dump(mode="json")
                for _entity, value in sorted(values.items())
            ],
        }

    @staticmethod
    def _json(response):
        def pairs(items):
            value = {}
            for key, child in items:
                if key in value:
                    raise ValueError
                value[key] = child
            return value

        types = [
            value.split(";", 1)[0].strip().lower()
            for name, value in response.headers
            if name.lower() == "content-type"
        ]
        if response.status != 200 or types != ["application/json"]:
            raise ValueError
        value = json.loads(
            response.body.decode("utf-8"), object_pairs_hook=pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
        validate_json_bounds(value)
        if not isinstance(value, dict) or not isinstance(
            value.get("attributes"), dict
        ):
            raise ValueError
        return value

    def _state(self, service, entity_id, current):
        try:
            with self._transport(
                service.base_url, timeout=5.0, max_bytes=MAX_STATE_BYTES
            ) as transport:
                response = transport.request(
                    "GET", "/api/states/" + entity_id,
                    headers={
                        "Authorization": "Bearer " + service.credentials["token"],
                        "Accept": "application/json",
                    },
                    before_send=current,
                )
            current()
            value = self._json(response)
            if value.get("entity_id") != entity_id:
                raise ValueError
            return value
        except ApiError:
            raise
        except (
            ProbeTransportError, KeyError, OSError, TypeError, ValueError,
            UnicodeError, RecursionError, json.JSONDecodeError,
        ):
            raise ApiError("presence_provider_unavailable", 503) from None

    @staticmethod
    def _timestamp(value):
        if not isinstance(value, str) or len(value) > 40:
            raise ValueError
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError
        milliseconds = int(parsed.astimezone(timezone.utc).timestamp() * 1000)
        if not 1 <= milliseconds <= MAX_SAFE_INTEGER:
            raise ValueError
        return milliseconds

    def _evidence(self, service, entity_id, candidate_id, current):
        registry = self._registry(service, current)
        entry = registry.get(entity_id)
        if entry is None or entry[0].candidateId != candidate_id:
            raise ApiError("revision_conflict", 409)
        candidate, registry_unique_id = entry
        state = self._state(service, entity_id, current)
        token = state.get("state")
        distance = state["attributes"].get("distance")
        if (
            not isinstance(token, str) or token in _UNAVAILABLE
            or not token.strip() or len(token) > 96
            or any(ord(char) < 32 or ord(char) == 127 for char in token)
            or type(distance) not in (int, float) or isinstance(distance, bool)
            or not math.isfinite(distance) or not 0 <= distance <= 1000
        ):
            raise ApiError("presence_provider_unavailable", 503)
        observed = self._timestamp(state.get("last_updated"))
        now = self.now_ms()
        if observed > now + 1000:
            raise ApiError("presence_provider_unavailable", 503)
        return VerifiedMqttRoomEntity(
            entity_name=candidate.name,
            entity_unique_id=registry_unique_id,
            provider_token=token.strip(),
            observed_at_ms=observed,
            distance_milli=round(distance * 1000),
        )

    def preflight(self, actor, service, body):
        def current():
            with self._db.connection() as connection:
                connection.execute("BEGIN")
                self._auth.assert_current(connection, actor)
                if self._connection(
                    connection, body.serviceId, body.expectedServiceRevision
                ) != service:
                    raise ApiError("revision_conflict", 409)
                self._room(
                    connection, body.roomId, body.expectedRoomRevision
                )
        return self._evidence(
            service, body.entityId, body.candidateId, current
        )

    def observe(self, actor, store):
        reservation = store.reserve_observation(actor)
        source, service, _actor_revision = reservation

        def current():
            store.assert_observation_current(actor, reservation)

        evidence = self._evidence(
            service, source.entityId,
            self._candidate_id(
                service, source.entityId, source.entityUniqueId
            ),
            current,
        )
        current()
        if self.now_ms() - evidence.observed_at_ms > source.maxSignalAgeMs:
            raise ApiError("presence_provider_stale", 503)
        mapping = next(
            (item for item in source.mappings
             if item.providerToken == evidence.provider_token),
            None,
        )
        if mapping is None:
            raise ApiError("presence_room_unmapped", 409)
        policy = store.policy(source)
        signal = {
            "schemaVersion": 1,
            "coreId": policy.coreId,
            "homeId": policy.homeId,
            "homeRevision": policy.homeRevision,
            "roomId": mapping.roomId,
            "roomRevision": mapping.roomRevision,
            "deviceId": policy.device.deviceId,
            "deviceRevision": policy.device.deviceRevision,
            "modelId": policy.device.modelId,
            "modelRevision": policy.device.modelRevision,
            "policyId": policy.policyId,
            "policyRevision": policy.policyRevision,
            "consentId": policy.device.consentId,
            "consentRevision": policy.device.consentRevision,
            "sourceId": policy.sources[0].sourceId,
            "sourceKind": "ha_mqtt_room",
            "sourceRevision": policy.sources[0].sourceRevision,
            "observationRevision": evidence.observed_at_ms,
            "rawIdentifier": source.entityUniqueId,
            "confidencePermille": 1000,
            "observedAtMs": evidence.observed_at_ms,
        }
        return source, policy, signal
