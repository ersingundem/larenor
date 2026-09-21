"""Authenticated, recommendation-only irrigation projection."""

from ..errors import ApiError
from .models import IrrigationAuthority


class IrrigationHttpGateway:
    def __init__(self, *, planner, provider, clock_ms):
        self._planner = planner
        self._provider = provider
        self._clock_ms = clock_ms

    def snapshot(self, actor):
        try:
            authority = IrrigationAuthority.model_validate(
                self._provider.authority(actor.id)
            )
            policy = self._provider.policy(authority)
            inputs = self._provider.inputs(actor, authority, policy)
            labels = self._provider.zone_labels(actor, authority, policy)
            capability = self._provider.control_capability(actor, authority, policy)
        except ApiError:
            raise
        except Exception:
            raise ApiError("irrigation_provider_unavailable", 503) from None
        if (
            authority.accountId != actor.id
            or authority.sessionFamilyId != actor.family_id
            or actor.role != "admin"
        ):
            raise ApiError("revision_conflict", 409)
        if not isinstance(inputs, dict) or set(inputs) != {
            "soil", "safety", "forecast", "budget", "overrides"
        }:
            raise ApiError("invalid_request")
        plan = self._planner.plan(
            authority,
            policy,
            inputs["soil"],
            inputs["safety"],
            inputs["forecast"],
            inputs["budget"],
            nowMs=self._clock_ms(),
            overrides=inputs["overrides"],
        )
        zones = {item.zone.zoneId for item in plan.items}
        if not isinstance(labels, dict) or set(labels) != zones:
            raise ApiError("revision_conflict", 409)
        for value in labels.values():
            if (
                not isinstance(value, dict)
                or set(value) != {"areaName", "plantName"}
                or any(
                    not isinstance(label, str)
                    or not 1 <= len(label) <= 120
                    or label != label.strip()
                    for label in value.values()
                )
            ):
                raise ApiError("revision_conflict", 409)
        if capability not in {"read_only", "manual_required"}:
            raise ApiError("irrigation_capability_unverified", 409)
        budget = inputs["budget"]
        forecast = inputs["forecast"]
        soil = {item["zoneId"]: item for item in inputs["soil"]}
        return {
            "schemaVersion": 1,
            "authority": authority,
            "policyId": policy["policyId"],
            "policyRevision": policy["policyRevision"],
            "planId": plan.planId,
            "generatedAtMs": plan.generatedAtMs,
            "forecastStatus": plan.forecastStatus,
            "rainMilliMm": forecast["rainMilliMm"],
            "budget": {
                "revision": budget["budgetRevision"],
                "dailyLimitMl": budget["dailyLimitMl"],
                "usedMl": budget["usedMl"],
                "plannedMl": plan.totalWaterMl,
                "estimatedCostMicros": plan.estimatedCostMicros,
            },
            "zones": [
                {
                    "zoneId": item.zone.zoneId,
                    "zoneRevision": item.zone.zoneRevision,
                    "areaName": labels[item.zone.zoneId]["areaName"],
                    "plantName": labels[item.zone.zoneId]["plantName"],
                    "moisturePermille": soil[item.zone.zoneId]["moisturePermille"],
                    "soilReadingRevision": soil[item.zone.zoneId]["readingRevision"],
                    "status": item.status,
                    "reason": item.reason,
                    "durationSeconds": item.durationSeconds,
                    "estimatedWaterMl": item.estimatedWaterMl,
                }
                for item in plan.items
            ],
            "controlCapability": capability,
            "commandEndpointAvailable": False,
        }
