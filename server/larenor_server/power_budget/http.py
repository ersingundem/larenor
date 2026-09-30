"""Authenticated, read-only power-budget projection for tablet clients."""

import hashlib
import hmac
import json
from dataclasses import asdict

from ..errors import ApiError


class PowerBudgetHttpGateway:
    def __init__(self, *, service, provider):
        self._service = service
        self._provider = provider

    @staticmethod
    def _preview_id(authority, inputs):
        raw = json.dumps(
            {"authority": asdict(authority), "inputs": asdict(inputs)},
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
        return "view-" + hashlib.sha256(raw).hexdigest()

    def _projection(self, actor):
        try:
            authority = self._provider.authority(actor)
            inputs = self._provider.inputs(actor, authority)
            labels = self._provider.load_labels(actor, authority)
            capability = self._provider.control_capability(actor, authority)
            enabled = (
                capability == "manual_required"
                and authority.can_control
                and callable(getattr(self._provider, "manual_control_enabled", None))
                and self._provider.manual_control_enabled(actor, authority) is True
            )
            raw_behaviors = (
                self._provider.communication_loss_behaviors(actor, authority)
                if enabled
                else {load.load_id: "not_applicable_read_only" for load in inputs.loads}
            )
        except ApiError:
            raise
        except Exception:
            raise ApiError("power_provider_unavailable", 503) from None
        if not isinstance(labels, dict) or set(labels) != {
            load.load_id for load in inputs.loads
        }:
            raise ApiError("power_inputs_unverified", 409)
        if any(
            not isinstance(key, str)
            or not isinstance(value, str)
            or not 1 <= len(value) <= 120
            or value != value.strip()
            for key, value in labels.items()
        ):
            raise ApiError("power_inputs_unverified", 409)
        if capability not in {"read_only", "manual_required"}:
            raise ApiError("power_capability_unverified", 409)
        allowed_behaviors = {
            "stop_charging",
            "hold_last_safe_limit",
            "provider_managed",
            "not_applicable_read_only",
        }
        load_ids = {load.load_id for load in inputs.loads}
        if (
            not isinstance(raw_behaviors, dict)
            or set(raw_behaviors) != load_ids
            or any(value not in allowed_behaviors for value in raw_behaviors.values())
        ):
            raise ApiError("power_capability_unverified", 409)
        preview = self._service.preview(
            actor,
            authority=authority,
            inputs=inputs,
            preview_id=self._preview_id(authority, inputs),
        )
        if enabled and any(
            raw_behaviors[action.load_id] != "hold_last_safe_limit"
            for action in preview.actions
        ):
            raise ApiError("power_capability_unverified", 409)
        return authority, inputs, labels, capability, enabled, raw_behaviors, preview

    def snapshot(self, actor):
        authority, inputs, labels, capability, enabled, behaviors, preview = (
            self._projection(actor)
        )
        return {
            "schemaVersion": 1,
            "authority": {
                "coreId": authority.core_id,
                "homeId": authority.home_id,
                "accountId": authority.account_id,
                "sessionId": authority.session_id,
                "coreRevision": authority.core_revision,
                "homeRevision": authority.home_revision,
                "accountRevision": authority.account_revision,
                "meterId": authority.meter_id,
                "meterRevision": authority.meter_revision,
                "tariffRevision": authority.tariff_revision,
                "loadRegistryRevision": authority.load_registry_revision,
                "gridLimitRevision": authority.grid_limit_revision,
                "overrideRevision": authority.override_revision,
                "planRevision": authority.plan_revision,
                "canControl": authority.can_control,
            },
            "measurement": {
                "gridImportW": inputs.grid_import_w,
                "gridLimitW": inputs.grid_limit_w,
                "tariffMicrosPerKwh": inputs.tariff_micros_per_kwh,
                "providerStatus": preview.provider_status,
            },
            "plan": {
                "id": preview.id,
                "status": preview.status,
                "planHash": preview.plan_hash,
                "planRevision": preview.plan_revision,
                "requiredReductionW": preview.required_reduction_w,
                "overrideExpiresAtMs": None
                if preview.override_expires_at is None
                else int(preview.override_expires_at * 1000),
                "actions": [
                    {
                        "loadId": item.load_id,
                        "label": labels[item.load_id],
                        "loadRevision": item.load_revision,
                        "reductionW": item.reduction_w,
                        "targetW": item.target_w,
                        "priority": item.priority,
                        "communicationLossBehavior": behaviors[item.load_id],
                    }
                    for item in preview.actions
                ],
            },
            "controlCapability": capability,
            "commandEndpointAvailable": enabled,
        }

    def confirm(self, actor, *, preview_id, expected_plan_hash, request_key):
        command_id = "manual-" + hashlib.sha256(
            f"{actor.id}\0{request_key}".encode("utf-8")
        ).hexdigest()
        existing = self._service.existing(
            actor,
            command_id=command_id,
            preview_id=preview_id,
            expected_plan_hash=expected_plan_hash,
        )
        if existing is not None:
            receipt, prior_preview = existing
            return {
                "schemaVersion": 1,
                "commandId": receipt.command_id,
                "previewId": receipt.preview_id,
                "planHash": receipt.plan_hash,
                "status": receipt.status,
                "applyCount": receipt.apply_count,
                "communicationLossBehavior": {
                    action.load_id: "hold_last_safe_limit"
                    for action in prior_preview.actions
                },
            }
        authority, _inputs, _labels, _capability, enabled, behaviors, preview = (
            self._projection(actor)
        )
        if not enabled:
            raise ApiError("power_capability_unverified", 409)
        if preview.id != preview_id or not hmac.compare_digest(
            preview.plan_hash, expected_plan_hash
        ):
            raise ApiError("power_budget_preview_changed", 409)
        receipt = self._service.confirm(
            actor,
            authority=authority,
            preview_id=preview_id,
            command_id=command_id,
            expected_plan_hash=expected_plan_hash,
        )
        if receipt.status == "awaiting_readback":
            receipt = self._service.readback(
                actor, authority=authority, command_id=command_id
            )
        return {
            "schemaVersion": 1,
            "commandId": receipt.command_id,
            "previewId": receipt.preview_id,
            "planHash": receipt.plan_hash,
            "status": receipt.status,
            "applyCount": receipt.apply_count,
            "communicationLossBehavior": {
                action.load_id: behaviors[action.load_id] for action in preview.actions
            },
        }
