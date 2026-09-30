"""Concrete, read-only Home Assistant irrigation observation provider.

Only fixed entity-state and weather-forecast routes are used. Generic Home
Assistant valves do not promise a timed run or flow receipt, so this provider
deliberately exposes ``manual_required`` rather than verified control.
"""

from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
import hashlib
import json
import math
import re

from ..errors import ApiError
from ..services.transport import ProbeResponse, ProbeTransportError, ServiceTransport
from ..vault import validate_json_bounds
from .models import IrrigationAuthority, IrrigationPolicy, IrrigationZone
from .source_store import IrrigationSourceStore


_IDENTITY = re.compile(r"[0-9a-f]{32}\Z")
_NUMBER = re.compile(r"-?[0-9]{1,12}(?:\.[0-9]{1,6})?\Z")
_TIMEOUT = 5.0
_MAX_BYTES = 65_536


class HomeAssistantIrrigationError(Exception):
    pass


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_key")
        result[key] = value
    return result


def _object(response):
    if (
        not isinstance(response, ProbeResponse)
        or response.status != 200
        or not isinstance(response.body, bytes)
        or len(response.body) > _MAX_BYTES
    ):
        raise HomeAssistantIrrigationError()
    content_types = [
        value.split(";", 1)[0].strip().lower()
        for name, value in response.headers
        if name.lower() == "content-type"
    ]
    if content_types != ["application/json"]:
        raise HomeAssistantIrrigationError()
    try:
        value = json.loads(
            response.body.decode("utf-8"),
            object_pairs_hook=_unique,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
        validate_json_bounds(value)
    except (UnicodeError, ValueError, TypeError, RecursionError, json.JSONDecodeError):
        raise HomeAssistantIrrigationError() from None
    if type(value) is not dict:
        raise HomeAssistantIrrigationError()
    return value


def _timestamp(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 40:
        raise HomeAssistantIrrigationError()
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise HomeAssistantIrrigationError() from None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise HomeAssistantIrrigationError()
    seconds = parsed.timestamp()
    if not math.isfinite(seconds) or not 0 <= seconds <= (2**63 - 1) / 1000:
        raise HomeAssistantIrrigationError()
    return int(seconds * 1000)


def _decimal(value, *, minimum, maximum):
    if not isinstance(value, str) or _NUMBER.fullmatch(value) is None:
        raise HomeAssistantIrrigationError()
    try:
        number = Decimal(value)
    except InvalidOperation:
        raise HomeAssistantIrrigationError() from None
    if not Decimal(str(minimum)) <= number <= Decimal(str(maximum)):
        raise HomeAssistantIrrigationError()
    return number


def _scaled(value, scale, *, minimum, maximum):
    number = _decimal(value, minimum=minimum, maximum=maximum)
    return int((number * scale).quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def _revision(value):
    raw = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    return int(hashlib.sha256(raw).hexdigest()[:15], 16) + 1


def _identity(*values):
    raw = json.dumps(values, ensure_ascii=False, separators=(",", ":")).encode()
    return hashlib.sha256(raw).hexdigest()[:32]


class HomeAssistantIrrigationProvider:
    def __init__(
        self, db, auth, settings, key, context, connection_resolver,
        home_resources, *,
        transport_factory=None,
    ):
        self._db, self._auth, self._settings = db, auth, settings
        self._context = context
        self._connection_resolver = connection_resolver
        self._home_resources = home_resources
        self._factory = transport_factory or ServiceTransport
        self.source_store = IrrigationSourceStore(
            db, auth, key, context, connection_resolver, self._room_context
        )
        self.source_store.validate_storage()

    def _room_context(self, connection, zones):
        self._home_resources._check_context(
            connection, self._context.coreId, self._context.homeId
        )
        state = self._home_resources._state(connection)
        rooms = {}
        for item in zones:
            row, ref, data = self._home_resources._target(
                connection, item.roomId
            )
            if ref.kind != "room" or row["revision"] != item.roomRevision:
                raise ApiError("revision_conflict", 409)
            rooms[item.roomId] = {
                "revision": row["revision"],
                "label": data.label,
            }
        return state["revision"], rooms

    def _authority(self, connection, *, account_id, family_id):
        row = connection.execute(
            "SELECT revision,role,disabled,must_change_password FROM users WHERE id=?",
            (account_id,),
        ).fetchone()
        family = connection.execute(
            "SELECT revoked_at,expires_at FROM session_families "
            "WHERE id=? AND user_id=?",
            (family_id, account_id),
        ).fetchone()
        now = self._settings.clock()
        if (
            row is None or family is None or row["disabled"]
            or row["must_change_password"] or row["role"] != "admin"
            or family["revoked_at"] is not None or now >= family["expires_at"]
        ):
            raise ApiError("revision_conflict", 409)
        self._home_resources._check_context(
            connection, self._context.coreId, self._context.homeId
        )
        home_revision = self._home_resources._state(connection)["revision"]
        return IrrigationAuthority(
            schemaVersion=1,
            coreId=self._context.coreId,
            homeId=self._context.homeId,
            homeRevision=home_revision,
            accountId=account_id,
            accountRevision=row["revision"],
            sessionFamilyId=family_id,
            role="admin",
            active=True,
            canManageIrrigation=True,
        )

    def authority_for_actor(self, actor):
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            self._auth.assert_current(connection, actor)
            return self._authority(
                connection, account_id=actor.id, family_id=actor.family_id
            )

    def current_authority(self, expected):
        expected = IrrigationAuthority.model_validate(expected)
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            current = self._authority(
                connection,
                account_id=expected.accountId,
                family_id=expected.sessionFamilyId,
            )
        return current

    # Compatibility for the existing injected provider protocol. Normal code
    # resolves current authority from the complete expected snapshot.
    def authority(self, expected):
        if isinstance(expected, IrrigationAuthority):
            return self.current_authority(expected)
        raise ApiError("revision_conflict", 409)

    def _zone(self, source, item, rooms):
        zone_id = _identity("irrigation-zone", item.valveEntityId)
        room = rooms[item.roomId]
        return IrrigationZone(
            schemaVersion=1,
            coreId=self._context.coreId,
            homeId=self._context.homeId,
            zoneId=zone_id,
            zoneRevision=source.revision,
            areaId=item.roomId,
            areaRevision=room["revision"],
            valveServiceId=source.serviceId,
            valveServiceRevision=source.serviceRevision,
            valveBindingId=_identity(
                "irrigation-ha-valve", source.serviceId, item.valveEntityId
            ),
            valveBindingRevision=source.revision,
            flowMlPerMinute=item.flowMlPerMinute,
            maxDurationSeconds=item.maxDurationSeconds,
        )

    def _policy(self, source, rooms):
        return IrrigationPolicy(
            schemaVersion=1,
            coreId=self._context.coreId,
            homeId=self._context.homeId,
            policyId=_identity("irrigation-policy", self._context.homeId),
            policyRevision=source.revision,
            zones=[self._zone(source, item, rooms) for item in source.zones],
            targetMoisturePermille=source.targetMoisturePermille,
            soilMaxAgeMs=source.soilMaxAgeMs,
            safetyMaxAgeMs=source.safetyMaxAgeMs,
            forecastMaxAgeMs=source.forecastMaxAgeMs,
            rainDeferralMilliMm=source.rainDeferralMilliMm,
            freezeThresholdMilliC=source.freezeThresholdMilliC,
            windLimitMilliMps=source.windLimitMilliMps,
            previewTtlMs=source.previewTtlMs,
            active=True,
        )

    def _source_context(self, *, actor=None, expected=None, service=False):
        with self._db.connection() as connection:
            connection.execute("BEGIN")
            if actor is not None:
                self.source_store._actor(connection, actor)
            source = self.source_store._decode(connection.execute(
                "SELECT * FROM irrigation_source WHERE singleton=1"
            ).fetchone())
            if expected is not None and source != expected:
                raise ApiError("revision_conflict", 409)
            home_revision, rooms = self._room_context(connection, source.zones)
            resolved_service = None
            if service:
                resolved_service = self._connection_resolver(
                    connection, source.serviceId, source.serviceRevision
                )
        return source, home_revision, rooms, resolved_service

    def policy(self, authority):
        source, home_revision, rooms, _service = self._source_context()
        if authority.homeRevision != home_revision:
            raise ApiError("revision_conflict", 409)
        return self._policy(source, rooms)

    def policy_by_id(self, policy_id):
        source, _home_revision, rooms, _service = self._source_context()
        value = self._policy(source, rooms)
        if policy_id != value.policyId:
            raise ApiError("revision_conflict", 409)
        return value

    def configuration(self, actor):
        return self.source_store.for_actor(actor)

    def configure(self, actor, value):
        return self.source_store.put(actor, value)

    @staticmethod
    def _headers(connection, *, body=False):
        try:
            token = connection.credentials["token"]
            token.encode("latin-1")
        except (KeyError, UnicodeError, AttributeError):
            raise HomeAssistantIrrigationError() from None
        headers = {"Authorization": "Bearer " + token, "Accept": "application/json"}
        if body:
            headers["Content-Type"] = "application/json"
        return headers

    def _request(self, connection, method, path, *, body=None, query=None):
        transport = None
        try:
            transport = self._factory(
                connection.base_url, timeout=_TIMEOUT, max_bytes=_MAX_BYTES
            )
            return transport.request(
                method, path,
                headers=self._headers(connection, body=body is not None),
                body=body,
                query_parameters=query,
            )
        except (ProbeTransportError, OSError, TypeError, ValueError):
            raise HomeAssistantIrrigationError() from None
        finally:
            if transport is not None:
                transport.close()

    def _state(self, connection, entity_id):
        value = _object(self._request(
            connection, "GET", "/api/states/" + entity_id
        ))
        if (
            value.get("entity_id") != entity_id
            or type(value.get("state")) is not str
            or type(value.get("attributes")) is not dict
        ):
            raise HomeAssistantIrrigationError()
        value["observedAtMs"] = _timestamp(value.get("last_updated"))
        return value

    def _forecast(self, connection, source, now_ms):
        body = json.dumps(
            {"entity_id": source.weatherEntityId, "type": "hourly"},
            separators=(",", ":"),
        ).encode("ascii")
        value = _object(self._request(
            connection, "POST", "/api/services/weather/get_forecasts",
            body=body, query={"return_response": ""},
        ))
        try:
            if set(value) != {"changed_states", "service_response"}:
                raise ValueError
            if type(value["changed_states"]) is not list:
                raise ValueError
            response = value["service_response"]
            if type(response) is not dict or set(response) != {source.weatherEntityId}:
                raise ValueError
            forecast = response[source.weatherEntityId]["forecast"]
            if not isinstance(forecast, list) or not 1 <= len(forecast) <= 32:
                raise ValueError
            rain = Decimal(0)
            valid = []
            for entry in forecast:
                if type(entry) is not dict:
                    raise ValueError
                at = _timestamp(entry["datetime"])
                if now_ms <= at <= now_ms + source.forecastMaxAgeMs:
                    precipitation = entry.get("precipitation")
                    if isinstance(precipitation, bool) or not isinstance(
                        precipitation, (int, float)
                    ) or not math.isfinite(float(precipitation)):
                        raise ValueError
                    amount = Decimal(str(precipitation))
                    if not 0 <= amount <= 10_000:
                        raise ValueError
                    rain += amount
                    valid.append(at)
            if not valid or rain > 10_000:
                raise ValueError
        except (KeyError, TypeError, ValueError, InvalidOperation):
            raise HomeAssistantIrrigationError() from None
        return {
            "schemaVersion": 1,
            "coreId": self._context.coreId,
            "homeId": self._context.homeId,
            "sourceId": _identity(
                "irrigation-weather", source.serviceId, source.weatherEntityId
            ),
            "sourceRevision": source.revision,
            "forecastRevision": _revision(value["service_response"]),
            "generatedAtMs": now_ms,
            "validUntilMs": now_ms + source.forecastMaxAgeMs,
            "rainMilliMm": int((rain * 1000).quantize(
                Decimal("1"), rounding=ROUND_HALF_UP
            )),
        }

    def inputs(self, actor, authority, policy):
        source, home_revision, rooms, service = self._source_context(
            actor=actor, service=True
        )
        if (
            authority.homeRevision != home_revision
            or self.current_authority(authority) != authority
            or self._policy(source, rooms) != IrrigationPolicy.model_validate(policy)
        ):
            raise ApiError("revision_conflict", 409)
        try:
            now_ms = int(self._settings.clock() * 1000)
            weather = self._state(service, source.weatherEntityId)
            leak = self._state(service, source.leakEntityId)
            water = self._state(service, source.dailyWaterEntityId)
            soils = [
                (item, self._state(service, item.soilMoistureEntityId))
                for item in source.zones
            ]
            # Observation includes the configured valve entities even though
            # generic valves cannot satisfy the verified timed-control contract.
            for item in source.zones:
                valve = self._state(service, item.valveEntityId)
                if valve["state"] not in {
                    "open", "opening", "closed", "closing", "stopped",
                    "unavailable", "unknown",
                }:
                    raise HomeAssistantIrrigationError()
            attrs = weather["attributes"]
            if (
                attrs.get("temperature_unit") != "°C"
                or attrs.get("wind_speed_unit") != "m/s"
                or attrs.get("precipitation_unit") != "mm"
            ):
                raise HomeAssistantIrrigationError()
            temperature = _scaled(
                str(attrs.get("temperature")), 1000,
                minimum=-100, maximum=100,
            )
            wind = _scaled(
                str(attrs.get("wind_speed")), 1000,
                minimum=0, maximum=200,
            )
            if (
                leak["state"] not in {"on", "off"}
                or leak["attributes"].get("device_class") != "moisture"
            ):
                raise HomeAssistantIrrigationError()
            water_attrs = water["attributes"]
            if (
                water_attrs.get("unit_of_measurement") not in {"L", "l"}
                or water_attrs.get("state_class") not in {"total", "total_increasing"}
            ):
                raise HomeAssistantIrrigationError()
            day_start = _timestamp(water_attrs.get("last_reset"))
            next_reset = _timestamp(water_attrs.get("next_reset"))
            if not day_start <= now_ms < next_reset or next_reset - day_start > 86_400_000:
                raise HomeAssistantIrrigationError()
            used_ml = _scaled(water["state"], 1000, minimum=0, maximum=10_000_000)
            if used_ml > source.dailyLimitMl:
                raise HomeAssistantIrrigationError()
            soil_values = []
            for item, state in soils:
                if (
                    state["attributes"].get("device_class") != "moisture"
                    or state["attributes"].get("unit_of_measurement") != "%"
                ):
                    raise HomeAssistantIrrigationError()
                zone = self._zone(source, item, rooms)
                soil_values.append({
                    "schemaVersion": 1,
                    "coreId": self._context.coreId,
                    "homeId": self._context.homeId,
                    "zoneId": zone.zoneId,
                    "zoneRevision": zone.zoneRevision,
                    "sensorId": _identity(
                        "irrigation-soil", source.serviceId,
                        item.soilMoistureEntityId,
                    ),
                    "sensorRevision": source.revision,
                    "readingRevision": _revision(state),
                    "moisturePermille": _scaled(
                        state["state"], 10, minimum=0, maximum=100
                    ),
                    "observedAtMs": state["observedAtMs"],
                })
            forecast = self._forecast(service, source, now_ms)
            result = {
                "soil": soil_values,
                "safety": {
                    "schemaVersion": 1,
                    "coreId": self._context.coreId,
                    "homeId": self._context.homeId,
                    "safetyRevision": _revision([weather, leak]),
                    "leakDetected": leak["state"] == "on",
                    "temperatureMilliC": temperature,
                    "windMilliMps": wind,
                    "observedAtMs": min(
                        weather["observedAtMs"], leak["observedAtMs"]
                    ),
                },
                "forecast": forecast,
                "budget": {
                    "schemaVersion": 1,
                    "coreId": self._context.coreId,
                    "homeId": self._context.homeId,
                    "budgetRevision": _revision(water),
                    "dayStartMs": day_start,
                    "dailyLimitMl": source.dailyLimitMl,
                    "usedMl": used_ml,
                    "priceMicrosPerLiter": source.priceMicrosPerLiter,
                },
                "overrides": [],
            }
        except HomeAssistantIrrigationError:
            raise ApiError("irrigation_provider_unavailable", 503) from None
        # Revalidate actor, source CAS, and encrypted service revision after IO.
        current, current_home_revision, current_rooms, _service = (
            self._source_context(actor=actor, expected=source, service=True)
        )
        if (
            current != source
            or current_home_revision != home_revision
            or current_rooms != rooms
            or self.current_authority(authority) != authority
        ):
            raise ApiError("revision_conflict", 409)
        return result

    def zone_labels(self, _actor, _authority, policy):
        source, _home_revision, rooms, _service = self._source_context()
        if self._policy(source, rooms) != IrrigationPolicy.model_validate(policy):
            raise ApiError("revision_conflict", 409)
        return {
            self._zone(source, item, rooms).zoneId: {
                "areaName": rooms[item.roomId]["label"],
                "plantName": item.plantName,
            }
            for item in source.zones
        }

    @staticmethod
    def control_capability(_actor, _authority, _policy):
        return "manual_required"
