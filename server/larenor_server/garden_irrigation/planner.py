"""Deterministic irrigation planning with advisory weather and hard safety gates."""

import hashlib
import json

from ..errors import ApiError
from .models import (
    IrrigationAuthority,
    IrrigationInputRevisions,
    IrrigationPlan,
    IrrigationPlanItem,
    IrrigationPolicy,
    IrrigationSafetySnapshot,
    ManualWaterOverride,
    RainForecast,
    SoilMoistureReading,
    WaterBudget,
)


def _hash(value) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


class IrrigationPlanner:
    def __init__(self, *, authorityResolver, policyResolver):
        self._resolve_authority = authorityResolver
        self._resolve_policy = policyResolver

    def _authority(self, raw):
        try:
            value = IrrigationAuthority.model_validate(raw)
        except ValueError:
            raise ApiError("invalid_request") from None
        try:
            current = IrrigationAuthority.model_validate(
                self._resolve_authority(value.accountId)
            )
        except Exception:  # noqa: BLE001 -- external state must fail closed.
            raise ApiError("forbidden", 403) from None
        if current != value:
            raise ApiError("revision_conflict", 409)
        if not value.active or value.role != "admin" or not value.canManageIrrigation:
            raise ApiError("forbidden", 403)
        return value

    def _policy(self, raw):
        try:
            value = IrrigationPolicy.model_validate(raw)
        except ValueError:
            raise ApiError("invalid_request") from None
        try:
            current = IrrigationPolicy.model_validate(
                self._resolve_policy(value.policyId)
            )
        except Exception:  # noqa: BLE001 -- external state must fail closed.
            raise ApiError("revision_conflict", 409) from None
        if current != value:
            raise ApiError("revision_conflict", 409)
        if not value.active:
            raise ApiError("forbidden", 403)
        return value

    def plan(
        self,
        rawAuthority,
        rawPolicy,
        rawSoil,
        rawSafety,
        rawForecast,
        rawBudget,
        *,
        nowMs,
        overrides=(),
    ):
        authority = self._authority(rawAuthority)
        policy = self._policy(rawPolicy)
        try:
            soil = [SoilMoistureReading.model_validate(item) for item in rawSoil]
            safety = IrrigationSafetySnapshot.model_validate(rawSafety)
            forecast = RainForecast.model_validate(rawForecast)
            budget = WaterBudget.model_validate(rawBudget)
            overrides = [ManualWaterOverride.model_validate(item) for item in overrides]
            if type(nowMs) is not int or nowMs < 0:
                raise ValueError
        except ValueError:
            raise ApiError("invalid_request") from None
        if (policy.coreId, policy.homeId) != (authority.coreId, authority.homeId):
            raise ApiError("not_found", 404)
        if any(
            (value.coreId, value.homeId) != (policy.coreId, policy.homeId)
            for value in (safety, forecast, budget)
        ):
            raise ApiError("not_found", 404)
        if not budget.dayStartMs <= nowMs < budget.dayStartMs + 24 * 60 * 60 * 1000:
            raise ApiError("revision_conflict", 409)
        zones = {item.zoneId: item for item in policy.zones}
        readings = {item.zoneId: item for item in soil}
        if len(readings) != len(soil) or set(readings) != set(zones):
            raise ApiError("revision_conflict", 409)
        for zone_id, reading in readings.items():
            zone = zones[zone_id]
            if (reading.coreId, reading.homeId, reading.zoneRevision) != (
                policy.coreId,
                policy.homeId,
                zone.zoneRevision,
            ):
                raise ApiError("revision_conflict", 409)
        active_overrides = {}
        for item in overrides:
            zone = zones.get(item.zoneId)
            if zone is None or (
                item.coreId,
                item.homeId,
                item.policyId,
                item.expectedPolicyRevision,
                item.expectedZoneRevision,
                item.actorAccountId,
            ) != (
                policy.coreId,
                policy.homeId,
                policy.policyId,
                policy.policyRevision,
                zone.zoneRevision,
                authority.accountId,
            ):
                raise ApiError("revision_conflict", 409)
            if item.createdAtMs > nowMs:
                raise ApiError("invalid_request")
            if item.durationSeconds > zone.maxDurationSeconds:
                raise ApiError("invalid_request")
            if item.zoneId in active_overrides:
                raise ApiError("invalid_request")
            if nowMs < item.expiresAtMs:
                active_overrides[item.zoneId] = item

        safety_reason = None
        if (
            safety.observedAtMs > nowMs
            or nowMs - safety.observedAtMs > policy.safetyMaxAgeMs
        ):
            safety_reason = "safety_stale"
        elif safety.leakDetected:
            safety_reason = "leak_detected"
        elif safety.temperatureMilliC <= policy.freezeThresholdMilliC:
            safety_reason = "freeze_risk"
        elif safety.windMilliMps >= policy.windLimitMilliMps:
            safety_reason = "wind_risk"
        forecast_available = (
            forecast.generatedAtMs <= nowMs <= forecast.validUntilMs
            and nowMs - forecast.generatedAtMs <= policy.forecastMaxAgeMs
        )
        remaining = budget.dailyLimitMl - budget.usedMl
        items = []
        for zone_id in sorted(zones):
            zone, reading = zones[zone_id], readings[zone_id]
            reason, status, duration = "moisture_deficit", "planned", 0
            if safety_reason is not None:
                reason, status = safety_reason, "blocked"
            elif (
                reading.observedAtMs > nowMs
                or nowMs - reading.observedAtMs > policy.soilMaxAgeMs
            ):
                reason, status = "soil_sensor_stale", "blocked"
            elif zone_id in active_overrides:
                reason, duration = (
                    "manual_override",
                    active_overrides[zone_id].durationSeconds,
                )
            elif reading.moisturePermille >= policy.targetMoisturePermille:
                reason, status = "moisture_sufficient", "skipped"
            elif (
                forecast_available
                and forecast.rainMilliMm >= policy.rainDeferralMilliMm
            ):
                reason, status = "rain_forecast", "deferred"
            else:
                deficit = policy.targetMoisturePermille - reading.moisturePermille
                duration = max(
                    1,
                    deficit * zone.maxDurationSeconds // policy.targetMoisturePermille,
                )
            water = max(1, duration * zone.flowMlPerMinute // 60) if duration else 0
            if status == "planned" and water > remaining:
                affordable_seconds = remaining * 60 // zone.flowMlPerMinute
                if affordable_seconds < 1:
                    reason, status, duration, water = (
                        "budget_exhausted",
                        "skipped",
                        0,
                        0,
                    )
                else:
                    duration = min(duration, affordable_seconds)
                    water = max(1, duration * zone.flowMlPerMinute // 60)
            if status != "planned":
                duration, water = 0, 0
            remaining -= water
            items.append(
                IrrigationPlanItem(
                    schemaVersion=1,
                    zone=zone,
                    status=status,
                    reason=reason,
                    durationSeconds=duration,
                    estimatedWaterMl=water,
                )
            )
        policy_hash = _hash(policy.model_dump(mode="json"))
        revisions = IrrigationInputRevisions(
            schemaVersion=1,
            policyRevision=policy.policyRevision,
            safetyRevision=safety.safetyRevision,
            forecastRevision=forecast.forecastRevision,
            budgetRevision=budget.budgetRevision,
            forecastSourceId=forecast.sourceId,
            forecastSourceRevision=forecast.sourceRevision,
            soilSensorIds={key: readings[key].sensorId for key in sorted(readings)},
            soilSensorRevisions={
                key: readings[key].sensorRevision for key in sorted(readings)
            },
            soilReadingRevisions={
                key: readings[key].readingRevision for key in sorted(readings)
            },
        )
        total = sum(item.estimatedWaterMl for item in items)
        identity = {
            "core": policy.coreId,
            "home": policy.homeId,
            "policyHash": policy_hash,
            "actor": authority.accountId,
            "accountRevision": authority.accountRevision,
            "at": nowMs,
            "inputs": revisions.model_dump(mode="json"),
            "soil": [readings[key].model_dump(mode="json") for key in sorted(readings)],
            "safety": safety.model_dump(mode="json"),
            "forecast": forecast.model_dump(mode="json"),
            "budget": budget.model_dump(mode="json"),
            "overrides": [
                item.model_dump(mode="json")
                for item in sorted(
                    active_overrides.values(), key=lambda value: value.zoneId
                )
            ],
            "items": [item.model_dump(mode="json") for item in items],
        }
        return IrrigationPlan(
            schemaVersion=1,
            planId=_hash(identity)[:32],
            coreId=policy.coreId,
            homeId=policy.homeId,
            homeRevision=authority.homeRevision,
            policyId=policy.policyId,
            policyRevision=policy.policyRevision,
            policyHash=policy_hash,
            actorAccountId=authority.accountId,
            accountRevision=authority.accountRevision,
            sessionFamilyId=authority.sessionFamilyId,
            generatedAtMs=nowMs,
            forecastStatus="available" if forecast_available else "stale",
            inputRevisions=revisions,
            items=items,
            totalWaterMl=total,
            estimatedCostMicros=total * budget.priceMicrosPerLiter // 1000,
        )
