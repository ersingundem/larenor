"""Read-only HA registry discovery and exact selected-source preflight."""

import json

from ..errors import ApiError
from ..home_assistant.read_only_websocket import (
    HomeAssistantReadOnlyWebSocket,
    HomeAssistantWebSocketError,
)
from ..services.transport import ProbeTransportError, ServiceTransport
from ..vault import validate_json_bounds


_MAX_ENTITIES = 4096
_MAX_BYTES = 65_536
_WEATHER_STATES = {
    "clear-night", "cloudy", "exceptional", "fog", "hail", "lightning",
    "lightning-rainy", "partlycloudy", "pouring", "rainy", "snowy",
    "snowy-rainy", "sunny", "windy", "windy-variant",
}


class RoomComfortProvisioner:
    def __init__(
        self, db, auth, services, home_resources, context,
        connection_resolver, resource_resolver,
        *, websocket_factory=None, transport_factory=None,
    ):
        self._db, self._auth, self._services = db, auth, services
        self._home_resources, self._context = home_resources, context
        self._connection_resolver = connection_resolver
        self._resource_resolver = resource_resolver
        self._websocket_factory = websocket_factory or HomeAssistantReadOnlyWebSocket
        self._transport_factory = transport_factory or ServiceTransport

    def _selected(self, service_id, revision):
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            return self._connection_resolver(connection, service_id, revision)

    def _guard(self, expected):
        current = self._selected(expected.id, expected.revision)
        if current != expected:
            raise ApiError("revision_conflict", 409)

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
            raise ApiError("comfort_limit_reached", 429)
        return {
            "schemaVersion": 1,
            "services": services,
            "rooms": [
                item for item in resources["entries"]
                if item["ref"]["kind"] == "room"
            ],
            "areas": [
                item for item in resources["entries"]
                if item["ref"]["kind"] == "resource"
            ],
        }

    def _registry(self, service):
        def current():
            self._guard(service)
        try:
            with self._websocket_factory(service).session(
                timeout=8.0, before_io=current, after_io=current
            ) as session:
                rows = session.list_entity_registry()
        except ApiError:
            raise
        except HomeAssistantWebSocketError:
            raise ApiError("comfort_provider_unavailable", 503) from None
        current()
        if len(rows) > _MAX_ENTITIES:
            raise ApiError("comfort_limit_reached", 429)
        values = {}
        for row in rows:
            entity = row.get("entity_id")
            if (
                not isinstance(entity, str)
                or len(entity) > 128
                or row.get("disabled_by") is not None
                or row.get("hidden_by") is not None
            ):
                continue
            if entity in values:
                raise ApiError("comfort_provider_unavailable", 503)
            values[entity] = row
        return values

    def entities(self, actor, service_id, revision):
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            self._auth.assert_current(connection, actor)
            service = self._connection_resolver(
                connection, service_id, revision
            )
        registry = self._registry(service)
        accepted = {
            domain: sorted(
                entity for entity in registry
                if entity.startswith(domain + ".")
            )
            for domain in (
                "climate", "cover", "sensor", "binary_sensor", "weather"
            )
        }
        return {"schemaVersion": 1, "entities": accepted}

    @staticmethod
    def _json(response):
        def unique(items):
            value = {}
            for key, child in items:
                if key in value:
                    raise ValueError
                value[key] = child
            return value
        if response.status != 200:
            raise ValueError
        types = [
            value.split(";", 1)[0].strip().lower()
            for name, value in response.headers
            if name.lower() == "content-type"
        ]
        if types != ["application/json"]:
            raise ValueError
        value = json.loads(
            response.body.decode(), object_pairs_hook=unique,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
        validate_json_bounds(value)
        if not isinstance(value, dict) or not isinstance(
            value.get("attributes"), dict
        ):
            raise ValueError
        return value

    def _state(self, service, entity):
        def current():
            self._guard(service)
        try:
            with self._transport_factory(
                service.base_url, timeout=5.0, max_bytes=_MAX_BYTES
            ) as transport:
                response = transport.request(
                    "GET", "/api/states/" + entity,
                    headers={
                        "Authorization": "Bearer " + service.credentials["token"],
                        "Accept": "application/json",
                    },
                    before_send=current,
                )
            current()
            value = self._json(response)
            if value.get("entity_id") != entity:
                raise ValueError
            return value
        except ApiError:
            raise
        except (
            ProbeTransportError, KeyError, OSError, TypeError, ValueError,
            UnicodeError, RecursionError, json.JSONDecodeError,
        ):
            raise ApiError("comfort_provider_unavailable", 503) from None

    def verify(self, body):
        service = self._selected(body.serviceId, body.expectedServiceRevision)
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            self._resource_resolver(connection, body.rooms)
        registry = self._registry(service)
        selected = {
            body.weatherEntityId, body.aqiEntityId,
            *(entity for room in body.rooms for entity in (
                room.climateEntityId, room.windowEntityId,
                room.temperatureEntityId, room.humidityEntityId,
                room.co2EntityId, room.vocEntityId,
                room.smokeEntityId, room.occupancyEntityId,
            )),
        }
        if not selected <= set(registry):
            raise ApiError("revision_conflict", 409)
        states = {entity: self._state(service, entity) for entity in selected}
        if (
            states[body.weatherEntityId]["attributes"].get("temperature_unit")
            != "°C"
            or states[body.weatherEntityId].get("state") not in _WEATHER_STATES
            or states[body.aqiEntityId]["attributes"].get(
                "unit_of_measurement"
            ) != "AQI"
        ):
            raise ApiError("revision_conflict", 409)
        for room in body.rooms:
            climate = states[room.climateEntityId]["attributes"]
            cover = states[room.windowEntityId]["attributes"]
            modes = climate.get("hvac_modes")
            features = cover.get("supported_features")
            if (
                not isinstance(modes, list)
                or any(not isinstance(mode, str) for mode in modes)
                or not {"off", "heat", "cool", "fan_only"} <= set(modes)
                or type(features) is not int
                or features & 3 != 3
            ):
                raise ApiError("revision_conflict", 409)
            units = {
                room.temperatureEntityId: "°C",
                room.humidityEntityId: "%",
                room.co2EntityId: "ppm",
                room.vocEntityId: "ppb",
            }
            if any(
                states[entity]["attributes"].get("unit_of_measurement") != unit
                for entity, unit in units.items()
            ):
                raise ApiError("revision_conflict", 409)
            if (
                states[room.smokeEntityId]["attributes"].get("device_class")
                != "smoke"
                or states[room.occupancyEntityId]["attributes"].get(
                    "device_class"
                ) not in {"occupancy", "presence", "motion"}
            ):
                raise ApiError("revision_conflict", 409)
