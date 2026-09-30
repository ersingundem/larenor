"""Fixed Home Assistant climate/cover executor with exact readback."""

from datetime import datetime
import hashlib
import json
import math
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP

from ..errors import ApiError
from ..services.transport import ProbeTransportError, ServiceTransport
from ..vault import validate_json_bounds
from .models import (
    ComfortDevice,
    ComfortDeviceReadback,
    MetricReading,
    OccupancySnapshot,
    OutdoorWeatherSnapshot,
    RoomClimateSnapshot,
    WorkerComfortReadback,
)


_TIMEOUT = 5.0
_MAX_BYTES = 65_536
_WEATHER_STATES = {
    "clear-night", "cloudy", "exceptional", "fog", "hail", "lightning",
    "lightning-rainy", "partlycloudy", "pouring", "rainy", "snowy",
    "snowy-rainy", "sunny", "windy", "windy-variant",
}


def _identity(*values):
    return hashlib.sha256(json.dumps(values, separators=(",", ":")).encode()).hexdigest()[:32]


def _timestamp(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 40:
        raise ValueError
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    seconds = parsed.timestamp()
    if parsed.tzinfo is None or not math.isfinite(seconds) or seconds < 0:
        raise ValueError
    return int(seconds * 1000)


def _json(response):
    def unique(items):
        value = {}
        for key, child in items:
            if key in value:
                raise ValueError
            value[key] = child
        return value

    types = [
        value.split(";", 1)[0].strip().lower()
        for name, value in response.headers if name.lower() == "content-type"
    ]
    if response.status != 200 or types != ["application/json"]:
        raise ValueError
    value = json.loads(
        response.body.decode(), object_pairs_hook=unique,
        parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
    )
    validate_json_bounds(value)
    if not isinstance(value, dict):
        raise ValueError
    return value


class HomeAssistantComfortExecutor:
    def __init__(self, source_store, *, transport_factory=None):
        self._source_store = source_store
        self._factory = transport_factory or ServiceTransport

    @staticmethod
    def device(source, room, kind):
        entity = room.climateEntityId if kind == "hvac" else room.windowEntityId
        return ComfortDevice(
            schemaVersion=1,
            kind=kind,
            deviceId=_identity("comfort-device", source.serviceId, entity),
            deviceRevision=source.revision,
            serviceId=source.serviceId,
            serviceRevision=source.serviceRevision,
            bindingId=_identity("comfort-binding", source.serviceId, entity),
            bindingRevision=source.revision,
        )

    def _binding(self, command, actor=None):
        source = self._source_store.get()
        matches = []
        for room in source.rooms:
            for kind in ("hvac", "window"):
                if (
                    room.roomId == command.roomId
                    and kind == command.targetKind
                    and self.device(source, room, kind) == command.device
                ):
                    entity = (
                        room.climateEntityId if kind == "hvac"
                        else room.windowEntityId
                    )
                    matches.append((source, room, entity))
        if len(matches) != 1:
            raise ApiError("revision_conflict", 409)
        source, room, entity = matches[0]
        if actor is None:
            return (
                source, room, entity, self._source_store.resolve(source), None
            )
        reservation = self._source_store.reserve_effect(actor, source)
        return source, room, entity, reservation[1], reservation

    @staticmethod
    def _headers(service, *, body=False):
        try:
            token = service.credentials["token"]
            token.encode("latin-1")
        except (KeyError, UnicodeError, AttributeError):
            raise ApiError("comfort_provider_unavailable", 503) from None
        result = {"Authorization": "Bearer " + token, "Accept": "application/json"}
        if body:
            result["Content-Type"] = "application/json"
        return result

    def _request(
        self, source, service, method, path, *, body=None,
        actor=None, reservation=None,
    ):
        def current():
            if actor is not None:
                self._source_store.assert_effect_current(actor, reservation)
                return
            if self._source_store.resolve(source) != service:
                raise ApiError("revision_conflict", 409)

        current()
        try:
            with self._factory(
                service.base_url, timeout=_TIMEOUT, max_bytes=_MAX_BYTES
            ) as transport:
                response = transport.request(
                    method, path,
                    headers=self._headers(service, body=body is not None),
                    body=body,
                    before_send=current,
                )
        except ApiError:
            raise
        except (ProbeTransportError, OSError, TypeError, ValueError):
            raise ApiError("comfort_provider_unavailable", 503) from None
        current()
        return response

    def _raw_state(
        self, source, service, entity, *, actor=None, reservation=None
    ):
        try:
            value = _json(self._request(
                source, service, "GET", "/api/states/" + entity,
                actor=actor, reservation=reservation,
            ))
            if value.get("entity_id") != entity or not isinstance(
                value.get("attributes"), dict
            ):
                raise ValueError
            return value, _timestamp(value.get("last_updated"))
        except ApiError:
            raise
        except (ValueError, TypeError, UnicodeError, RecursionError, json.JSONDecodeError):
            raise ApiError("comfort_provider_unavailable", 503) from None

    def _state(
        self, source, service, entity, kind, *, actor=None, reservation=None
    ):
        try:
            value, observed = self._raw_state(
                source, service, entity,
                actor=actor, reservation=reservation,
            )
            raw = value.get("state")
            if kind == "hvac":
                state = {"off": "off", "heat": "heat", "cool": "cool",
                         "fan_only": "ventilate"}.get(raw)
            else:
                state = {"open": "open", "closed": "closed"}.get(raw)
            if state is None:
                raise ValueError
            return state, observed, observed
        except ApiError:
            raise
        except (ValueError, TypeError, UnicodeError, RecursionError, json.JSONDecodeError):
            raise ApiError("comfort_provider_unavailable", 503) from None

    @staticmethod
    def _number(value, scale, minimum, maximum):
        if not isinstance(value, str) or len(value) > 32:
            raise ApiError("comfort_provider_unavailable", 503)
        try:
            number = Decimal(value)
        except InvalidOperation:
            raise ApiError("comfort_provider_unavailable", 503) from None
        if not number.is_finite() or not Decimal(str(minimum)) <= number <= Decimal(str(maximum)):
            raise ApiError("comfort_provider_unavailable", 503)
        return int((number * scale).quantize(Decimal("1"), rounding=ROUND_HALF_UP))

    def inputs(self):
        home_revision, policy = self._source_store.policy()
        source = self._source_store.get()
        service = self._source_store.resolve(source)
        now_ms = 0
        climates, occupancy, readbacks = [], [], []
        metric_specs = (
            ("temperature_millic", "temperatureEntityId", "°C", 1000, -50, 80),
            ("humidity_permille", "humidityEntityId", "%", 10, 0, 100),
            ("co2_ppm", "co2EntityId", "ppm", 1, 0, 100_000),
            ("voc_ppb", "vocEntityId", "ppb", 1, 0, 1_000_000),
        )
        for room in source.rooms:
            metrics = {}
            observed_values = []
            for kind, field, unit, scale, minimum, maximum in metric_specs:
                entity = getattr(room, field)
                raw, observed = self._raw_state(source, service, entity)
                if raw["attributes"].get("unit_of_measurement") != unit:
                    raise ApiError("comfort_provider_unavailable", 503)
                metrics[kind] = MetricReading(
                    schemaVersion=1,
                    kind=kind,
                    sensorId=_identity("comfort-sensor", source.serviceId, entity),
                    sensorRevision=source.revision,
                    readingRevision=observed,
                    value=self._number(raw["state"], scale, minimum, maximum),
                    observedAtMs=observed,
                )
                observed_values.append(observed)
            smoke, smoke_at = self._raw_state(
                source, service, room.smokeEntityId
            )
            occupied, occupied_at = self._raw_state(
                source, service, room.occupancyEntityId
            )
            if (
                smoke["state"] not in {"on", "off"}
                or smoke["attributes"].get("device_class") != "smoke"
                or occupied["state"] not in {"on", "off"}
                or occupied["attributes"].get("device_class")
                not in {"occupancy", "presence", "motion"}
            ):
                raise ApiError("comfort_provider_unavailable", 503)
            climates.append(RoomClimateSnapshot(
                schemaVersion=1,
                coreId=policy.coreId,
                homeId=policy.homeId,
                roomId=room.roomId,
                roomRevision=room.roomRevision,
                snapshotRevision=max(*observed_values, smoke_at),
                temperature=metrics["temperature_millic"],
                humidity=metrics["humidity_permille"],
                co2=metrics["co2_ppm"],
                voc=metrics["voc_ppb"],
                smokeDetected=smoke["state"] == "on",
                smokeSensorId=_identity(
                    "comfort-sensor", source.serviceId, room.smokeEntityId
                ),
                smokeSensorRevision=source.revision,
                smokeReadingRevision=smoke_at,
                smokeObservedAtMs=smoke_at,
            ))
            occupancy.append(OccupancySnapshot(
                schemaVersion=1,
                coreId=policy.coreId,
                homeId=policy.homeId,
                roomId=room.roomId,
                roomRevision=room.roomRevision,
                sourceId=_identity(
                    "comfort-occupancy", source.serviceId,
                    room.occupancyEntityId,
                ),
                sourceRevision=source.revision,
                occupancyRevision=occupied_at,
                occupied=occupied["state"] == "on",
                observedAtMs=occupied_at,
            ))
            for kind, entity in (
                ("hvac", room.climateEntityId),
                ("window", room.windowEntityId),
            ):
                state, revision, observed = self._state(
                    source, service, entity, kind
                )
                readbacks.append(ComfortDeviceReadback(
                    schemaVersion=1,
                    coreId=policy.coreId,
                    homeId=policy.homeId,
                    roomId=room.roomId,
                    device=self.device(source, room, kind),
                    stateRevision=revision,
                    state=state,
                    observedAtMs=observed,
                ))
            now_ms = max(now_ms, *observed_values, smoke_at, occupied_at)
        weather, weather_at = self._raw_state(
            source, service, source.weatherEntityId
        )
        aqi, aqi_at = self._raw_state(source, service, source.aqiEntityId)
        if (
            weather["attributes"].get("temperature_unit") != "°C"
            or weather.get("state") not in _WEATHER_STATES
            or aqi["attributes"].get("unit_of_measurement") != "AQI"
        ):
            raise ApiError("comfort_provider_unavailable", 503)
        weather_value = OutdoorWeatherSnapshot(
            schemaVersion=1,
            coreId=policy.coreId,
            homeId=policy.homeId,
            sourceId=_identity(
                "comfort-weather", source.serviceId, source.weatherEntityId,
                source.aqiEntityId,
            ),
            sourceRevision=source.revision,
            weatherRevision=max(weather_at, aqi_at),
            temperatureMilliC=self._number(
                str(weather["attributes"].get("temperature")), 1000, -100, 100
            ),
            raining=weather["state"] in {
                "rainy", "pouring", "lightning-rainy", "hail",
            },
            airQualityIndex=self._number(aqi["state"], 1, 0, 500),
            observedAtMs=min(weather_at, aqi_at),
        )
        now_ms = max(now_ms, weather_at, aqi_at)
        return home_revision, policy, climates, weather_value, occupancy, readbacks, now_ms

    def _execute(self, command, *, actor=None):
        source, _room, entity, service, reservation = self._binding(
            command, actor
        )
        before, revision, _observed = self._state(
            source, service, entity, command.targetKind,
            actor=actor, reservation=reservation,
        )
        if revision != command.expectedStateRevision:
            raise ApiError("revision_conflict", 409)
        if before != command.desiredState:
            if command.targetKind == "hvac":
                mode = "fan_only" if command.desiredState == "ventilate" else command.desiredState
                path = "/api/services/climate/set_hvac_mode"
                payload = {"entity_id": entity, "hvac_mode": mode}
            else:
                action = "open_cover" if command.desiredState == "open" else "close_cover"
                path = "/api/services/cover/" + action
                payload = {"entity_id": entity}
            response = self._request(
                source, service, "POST", path,
                body=json.dumps(payload, separators=(",", ":")).encode("ascii"),
                actor=actor, reservation=reservation,
            )
            if response.status != 200:
                if response.status in {400, 401, 403, 404, 405, 422}:
                    raise ApiError("comfort_command_rejected", 409)
                raise ApiError("comfort_provider_unavailable", 503)
        state, state_revision, observed_at = self._state(
            source, service, entity, command.targetKind,
            actor=actor, reservation=reservation,
        )
        return WorkerComfortReadback(
            schemaVersion=1,
            commandId=command.commandId,
            roomId=command.roomId,
            device=command.device,
            stateRevision=state_revision,
            state=state,
            observedAtMs=observed_at,
        )

    def execute_authorized(self, command, actor):
        return self._execute(command, actor=actor)

    def __call__(self, command):
        """Compatibility seam for isolated executor tests; Core uses authorization."""
        return self._execute(command)
