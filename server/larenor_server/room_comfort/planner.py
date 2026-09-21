"""Deterministic comfort recommendations with hard environmental safety gates."""

import hashlib
import json

from ..errors import ApiError
from .models import (
    ComfortAuthority, ComfortInputRevisions, ComfortPlan, ComfortPlanItem,
    ComfortPolicy, ManualComfortOverride, OccupancySnapshot,
    OutdoorWeatherSnapshot, RoomClimateSnapshot,
)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


class ComfortPlanner:
    def __init__(self, *, authorityResolver, policyResolver):
        self._resolve_authority, self._resolve_policy = authorityResolver, policyResolver

    def _authority(self, raw):
        try:
            value = ComfortAuthority.model_validate(raw)
        except ValueError:
            raise ApiError("invalid_request") from None
        try:
            current = ComfortAuthority.model_validate(self._resolve_authority(value.accountId))
        except Exception:
            raise ApiError("forbidden", 403) from None
        if current != value:
            raise ApiError("revision_conflict", 409)
        if not value.active or value.role != "admin" or not value.canManageComfort:
            raise ApiError("forbidden", 403)
        return value

    def _policy(self, raw):
        try:
            value = ComfortPolicy.model_validate(raw)
        except ValueError:
            raise ApiError("invalid_request") from None
        try:
            current = ComfortPolicy.model_validate(self._resolve_policy(value.policyId))
        except Exception:
            raise ApiError("revision_conflict", 409) from None
        if current != value:
            raise ApiError("revision_conflict", 409)
        if not value.active:
            raise ApiError("forbidden", 403)
        return value

    def plan(self, rawAuthority, rawPolicy, rawClimate, rawWeather, rawOccupancy,
             *, nowMs, overrides=()):
        authority, policy = self._authority(rawAuthority), self._policy(rawPolicy)
        try:
            climate = [RoomClimateSnapshot.model_validate(item) for item in rawClimate]
            weather = OutdoorWeatherSnapshot.model_validate(rawWeather)
            occupancy = [OccupancySnapshot.model_validate(item) for item in rawOccupancy]
            overrides = [ManualComfortOverride.model_validate(item) for item in overrides]
            if type(nowMs) is not int or nowMs < 0:
                raise ValueError
        except ValueError:
            raise ApiError("invalid_request") from None
        if (policy.coreId, policy.homeId) != (authority.coreId, authority.homeId):
            raise ApiError("not_found", 404)
        if (weather.coreId, weather.homeId) != (policy.coreId, policy.homeId):
            raise ApiError("not_found", 404)
        rooms = {item.roomId: item for item in policy.rooms}
        climates = {item.roomId: item for item in climate}
        occupancies = {item.roomId: item for item in occupancy}
        if (len(climates) != len(climate) or len(occupancies) != len(occupancy)
                or set(climates) != set(rooms) or set(occupancies) != set(rooms)):
            raise ApiError("revision_conflict", 409)
        for room_id, scope in rooms.items():
            inside, occupied = climates[room_id], occupancies[room_id]
            if ((inside.coreId, inside.homeId, inside.roomRevision)
                    != (policy.coreId, policy.homeId, scope.roomRevision)
                    or (occupied.coreId, occupied.homeId, occupied.roomRevision)
                    != (policy.coreId, policy.homeId, scope.roomRevision)):
                raise ApiError("revision_conflict", 409)
        active_overrides = {}
        for value in overrides:
            scope = rooms.get(value.roomId)
            if scope is None or (
                value.coreId, value.homeId, value.policyId,
                value.expectedPolicyRevision, value.expectedRoomRevision,
                value.actorAccountId,
            ) != (
                policy.coreId, policy.homeId, policy.policyId,
                policy.policyRevision, scope.roomRevision, authority.accountId,
            ):
                raise ApiError("revision_conflict", 409)
            if value.createdAtMs > nowMs or value.roomId in active_overrides:
                raise ApiError("invalid_request")
            if nowMs < value.expiresAtMs:
                active_overrides[value.roomId] = value

        weather_stale = (
            weather.observedAtMs > nowMs
            or nowMs - weather.observedAtMs > policy.outdoorMaxAgeMs
        )
        items, occupancy_advisory = [], {}
        for room_id in sorted(rooms):
            scope, inside, occupied = rooms[room_id], climates[room_id], occupancies[room_id]
            metric_values = (inside.temperature, inside.humidity, inside.co2, inside.voc)
            indoor_stale = any(
                value.observedAtMs > nowMs
                or nowMs - value.observedAtMs > policy.indoorMaxAgeMs
                for value in metric_values
            ) or inside.smokeObservedAtMs > nowMs or nowMs - inside.smokeObservedAtMs > policy.indoorMaxAgeMs
            occupancy_stale = (
                occupied.observedAtMs > nowMs
                or nowMs - occupied.observedAtMs > policy.occupancyMaxAgeMs
            )
            occupancy_advisory[room_id] = (
                "stale" if occupancy_stale else "occupied" if occupied.occupied else "unoccupied"
            )
            status, reason, hvac, window = "planned", "comfortable", "off", "closed"
            air_refresh = (
                inside.humidity.value >= policy.humidityHighPermille
                or inside.co2.value >= policy.co2HighPpm
                or inside.voc.value >= policy.vocHighPpb
            )
            if indoor_stale or weather_stale:
                status, reason = "blocked", "sensor_stale"
            elif inside.smokeDetected:
                status, reason = "blocked", "smoke_detected"
            elif weather.temperatureMilliC <= policy.freezeThresholdMilliC:
                status, reason = "blocked", "freeze_risk"
                if inside.temperature.value < policy.targetTemperatureMilliC - policy.temperatureToleranceMilliC:
                    hvac = "heat"
            elif air_refresh and weather.raining:
                status, reason = "blocked", "rain_window_block"
            elif air_refresh and weather.airQualityIndex >= policy.outdoorAqiLimit:
                status, reason = "blocked", "outdoor_air_unsafe"
            elif room_id in active_overrides:
                value = active_overrides[room_id]
                reason, hvac, window = "manual_override", value.hvacMode, value.windowState
            elif air_refresh:
                reason, hvac, window = "air_refresh", "off", "open"
            elif inside.temperature.value < policy.targetTemperatureMilliC - policy.temperatureToleranceMilliC:
                reason, hvac = "temperature_low", "heat"
            elif inside.temperature.value > policy.targetTemperatureMilliC + policy.temperatureToleranceMilliC:
                reason, hvac = "temperature_high", "cool"
            else:
                status = "skipped"
            items.append(ComfortPlanItem(
                schemaVersion=1, room=scope, status=status, reason=reason,
                hvacMode=hvac, windowState=window,
            ))
        policy_hash = digest(policy.model_dump(mode="json"))
        revisions = ComfortInputRevisions(
            schemaVersion=1, policyRevision=policy.policyRevision,
            weatherRevision=weather.weatherRevision,
            weatherSourceId=weather.sourceId,
            weatherSourceRevision=weather.sourceRevision,
            roomSnapshotRevisions={key: climates[key].snapshotRevision for key in sorted(climates)},
            occupancyRevisions={key: occupancies[key].occupancyRevision for key in sorted(occupancies)},
            occupancySourceIds={key: occupancies[key].sourceId for key in sorted(occupancies)},
            occupancySourceRevisions={
                key: occupancies[key].sourceRevision for key in sorted(occupancies)
            },
            metricSensorRevisions={
                key: {
                    "temperature_millic": climates[key].temperature.sensorRevision,
                    "humidity_permille": climates[key].humidity.sensorRevision,
                    "co2_ppm": climates[key].co2.sensorRevision,
                    "voc_ppb": climates[key].voc.sensorRevision,
                }
                for key in sorted(climates)
            },
            metricReadingRevisions={
                key: {
                    "temperature_millic": climates[key].temperature.readingRevision,
                    "humidity_permille": climates[key].humidity.readingRevision,
                    "co2_ppm": climates[key].co2.readingRevision,
                    "voc_ppb": climates[key].voc.readingRevision,
                }
                for key in sorted(climates)
            },
            smokeSensorRevisions={
                key: climates[key].smokeSensorRevision for key in sorted(climates)
            },
            smokeReadingRevisions={
                key: climates[key].smokeReadingRevision for key in sorted(climates)
            },
        )
        identity = dict(
            policy=policy.model_dump(mode="json"),
            climate=[climates[key].model_dump(mode="json") for key in sorted(climates)],
            weather=weather.model_dump(mode="json"),
            occupancy=[occupancies[key].model_dump(mode="json") for key in sorted(occupancies)],
            overrides=[active_overrides[key].model_dump(mode="json") for key in sorted(active_overrides)],
            actor=authority.accountId, accountRevision=authority.accountRevision,
            generatedAtMs=nowMs, items=[item.model_dump(mode="json") for item in items],
        )
        return ComfortPlan(
            schemaVersion=1, planId=digest(identity)[:32], coreId=policy.coreId,
            homeId=policy.homeId, homeRevision=authority.homeRevision,
            policyId=policy.policyId, policyRevision=policy.policyRevision,
            policyHash=policy_hash, actorAccountId=authority.accountId,
            accountRevision=authority.accountRevision,
            sessionFamilyId=authority.sessionFamilyId, generatedAtMs=nowMs,
            inputRevisions=revisions, occupancyAdvisory=occupancy_advisory,
            items=items,
        )
