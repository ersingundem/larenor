"""Authenticated irrigation planning and verified valve effect boundary."""

from collections import OrderedDict
import threading

from ..errors import ApiError
from .audit import TamperEvidentIrrigationAudit
from .effects import IrrigationCoordinator
from .models import (
    IrrigationAuthority,
    IrrigationConfirmRequest,
    IrrigationPolicy,
    IrrigationPreviewRequest,
    IrrigationStopRequest,
)

MAX_LIVE_PLANS = 64


class IrrigationHttpGateway:
    def __init__(self, *, planner, provider, clock_ms):
        self._planner = planner
        self._provider = provider
        self._clock_ms = clock_ms
        self._plans = OrderedDict()
        self._preview_plans = OrderedDict()
        self._coordinator = None
        self._control_key = None
        self._lock = threading.RLock()

    def _load(self, actor):
        try:
            authority = IrrigationAuthority.model_validate(
                self._provider.authority(actor.id)
            )
            policy = self._provider.policy(authority)
            policy_model = IrrigationPolicy.model_validate(policy)
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
            if capability != "verified_control":
                raise ApiError("irrigation_capability_unverified", 409)
            self._ensure_control(actor, authority, policy_model)
        budget = inputs["budget"]
        forecast = inputs["forecast"]
        soil = {item["zoneId"]: item for item in inputs["soil"]}
        projection = {
            "schemaVersion": 1,
            "authority": authority,
            "policyId": policy_model.policyId,
            "policyRevision": policy_model.policyRevision,
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
            "commandEndpointAvailable": capability == "verified_control",
        }
        with self._lock:
            self._plans[plan.planId] = plan
            self._plans.move_to_end(plan.planId)
            while len(self._plans) > MAX_LIVE_PLANS:
                self._plans.popitem(last=False)
        return projection, authority, policy_model, inputs, plan

    def snapshot(self, actor):
        return self._load(actor)[0]

    def _ensure_control(self, actor, authority, policy):
        required = (
            "control_key", "valve_readbacks", "valve_worker", "stop_valve"
        )
        if any(not callable(getattr(self._provider, name, None)) for name in required):
            raise ApiError("irrigation_capability_unverified", 409)
        try:
            key = self._provider.control_key(actor, authority, policy)
        except Exception:
            raise ApiError("irrigation_capability_unverified", 409) from None
        if not isinstance(key, bytes) or len(key) < 32:
            raise ApiError("irrigation_capability_unverified", 409)
        with self._lock:
            if self._control_key is not None and self._control_key != key:
                raise ApiError("revision_conflict", 409)
            if self._coordinator is None:
                self._control_key = key
                audit = TamperEvidentIrrigationAudit(
                    key=key, coreId=authority.coreId, homeId=authority.homeId
                )
                self._coordinator = IrrigationCoordinator(
                    audit=audit,
                    authorityResolver=self._provider.authority,
                    policyResolver=self._provider.policy_by_id,
                    planResolver=self._plan,
                )

    def _plan(self, plan_id):
        with self._lock:
            return self._plans.get(plan_id)

    def preview(self, actor, raw):
        body = IrrigationPreviewRequest.model_validate(raw)
        projection, authority, policy, inputs, plan = self._load(actor)
        if not projection["commandEndpointAvailable"]:
            raise ApiError("irrigation_control_unavailable", 409)
        if (
            body.expectedPlanId != plan.planId
            or body.expectedPolicyRevision != policy.policyRevision
            or body.expectedBudgetRevision != inputs["budget"]["budgetRevision"]
        ):
            raise ApiError("revision_conflict", 409)
        zones = [
            item.zone.zoneId for item in plan.items if item.status == "planned"
        ]
        if not zones:
            raise ApiError("irrigation_plan_empty", 409)
        try:
            readbacks = self._provider.valve_readbacks(
                actor, authority, policy, tuple(sorted(zones))
            )
        except Exception:
            raise ApiError("irrigation_provider_unavailable", 503) from None
        preview = self._coordinator.preview(
            authority, plan, readbacks,
            requestId=body.requestId, nowMs=self._clock_ms(),
        )
        with self._lock:
            self._preview_plans[preview.previewId] = plan.planId
            self._preview_plans.move_to_end(preview.previewId)
            while len(self._preview_plans) > 1024:
                self._preview_plans.popitem(last=False)
        return preview

    def confirm(self, actor, raw, *, cancelled=lambda: False):
        body = IrrigationConfirmRequest.model_validate(raw)
        _projection, authority, _policy, _inputs, current_plan = self._load(actor)
        if self._coordinator is None:
            raise ApiError("irrigation_control_unavailable", 409)
        with self._lock:
            expected_plan_id = self._preview_plans.get(body.previewId)
            expected_plan = (
                None if expected_plan_id is None
                else self._plans.get(expected_plan_id)
            )
        if (
            expected_plan is None
            or current_plan.policyHash != expected_plan.policyHash
            or current_plan.inputRevisions != expected_plan.inputRevisions
            or current_plan.items != expected_plan.items
            or current_plan.totalWaterMl != expected_plan.totalWaterMl
        ):
            raise ApiError("revision_conflict", 409)

        def apply(command):
            return self._provider.valve_worker(command, cancelled=cancelled)

        return self._coordinator.confirm(
            authority, body.previewId, body.confirmToken,
            nowMs=self._clock_ms(), worker=apply, cancelled=cancelled,
            stopWorker=self._provider.stop_valve,
        )

    def stop(self, actor, raw):
        body = IrrigationStopRequest.model_validate(raw)
        authority, policy = self._control_context(actor)
        if body.expectedPolicyRevision != policy.policyRevision:
            raise ApiError("revision_conflict", 409)
        valid = {item.zoneId for item in policy.zones}
        if any(zone_id not in valid for zone_id in body.zoneIds):
            raise ApiError("not_found", 404)
        try:
            readbacks = self._provider.valve_readbacks(
                actor, authority, policy, tuple(sorted(body.zoneIds))
            )
        except Exception:
            raise ApiError("irrigation_provider_unavailable", 503) from None
        return self._coordinator.stop(
            authority, policy, readbacks, body.zoneIds,
            requestId=body.requestId, nowMs=self._clock_ms(),
            worker=self._provider.stop_valve,
        )

    def _control_context(self, actor):
        try:
            authority = IrrigationAuthority.model_validate(
                self._provider.authority(actor.id)
            )
            policy = IrrigationPolicy.model_validate(
                self._provider.policy(authority)
            )
            capability = self._provider.control_capability(
                actor, authority, policy
            )
        except Exception:
            raise ApiError("irrigation_provider_unavailable", 503) from None
        if (
            authority.accountId != actor.id
            or authority.sessionFamilyId != actor.family_id
            or actor.role != "admin"
            or capability != "verified_control"
        ):
            raise ApiError("revision_conflict", 409)
        self._ensure_control(actor, authority, policy)
        return authority, policy
