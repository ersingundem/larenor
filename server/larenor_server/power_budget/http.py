"""Authenticated, read-only power-budget projection for tablet clients."""

import hashlib
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

    def snapshot(self, actor):
        try:
            authority = self._provider.authority(actor)
            inputs = self._provider.inputs(actor, authority)
            labels = self._provider.load_labels(actor, authority)
            capability = self._provider.control_capability(actor, authority)
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
        preview = self._service.preview(
            actor,
            authority=authority,
            inputs=inputs,
            preview_id=self._preview_id(authority, inputs),
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
                    }
                    for item in preview.actions
                ],
            },
            "controlCapability": capability,
            "commandEndpointAvailable": False,
        }
