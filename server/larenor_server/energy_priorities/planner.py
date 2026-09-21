"""Deterministic advisory planner; it never dispatches inverter effects."""

import hashlib
import json
from typing import Callable

from ..errors import ApiError
from .models import EnergyAuthority, EnergyInputs, EnergyPlan, EnergyPlanSlot


class EnergyPlanner:
    def __init__(
        self,
        *,
        authorityResolver: Callable[[str], EnergyAuthority | None],
        inputResolver: Callable[[str], EnergyInputs | None],
        clockMs: Callable[[], int],
    ):
        self._resolve_authority = authorityResolver
        self._resolve_inputs = inputResolver
        self._clock = clockMs

    def _authority(self, presented):
        try:
            authority = EnergyAuthority.model_validate(presented)
            current = self._resolve_authority(authority.accountId)
            current = None if current is None else EnergyAuthority.model_validate(current)
        except Exception:
            raise ApiError("forbidden", 403) from None
        if current is None:
            raise ApiError("forbidden", 403)
        if current != authority:
            raise ApiError("revision_conflict", 409)
        if not authority.active or not authority.canPlan:
            raise ApiError("forbidden", 403)
        return authority

    @staticmethod
    def _digest(source):
        raw = source.model_dump_json(exclude_none=False).encode("utf-8")
        return hashlib.sha256(raw).hexdigest()

    def plan(self, presentedAuthority, rawInputs) -> EnergyPlan:
        authority = self._authority(presentedAuthority)
        try:
            source = EnergyInputs.model_validate(rawInputs)
        except Exception:
            raise ApiError("invalid_request") from None
        try:
            current = self._resolve_inputs(source.battery.resourceId)
            current = None if current is None else EnergyInputs.model_validate(current)
        except Exception:
            raise ApiError("server_unavailable", 503) from None
        if current is None:
            raise ApiError("not_found", 404)
        if current != source or (
            source.coreId,
            source.homeId,
            source.homeRevision,
        ) != (authority.coreId, authority.homeId, authority.homeRevision):
            raise ApiError("revision_conflict", 409)

        now = self._clock()
        override = source.manualOverride
        override_status = (
            "none" if override is None else "active" if now < override.expiresAtMs else "expired"
        )
        input_digest = self._digest(source)
        plan_payload = json.dumps(
            ["f47-energy-plan-v1", input_digest, override_status],
            separators=(",", ":"),
        ).encode("ascii")
        plan_id = hashlib.sha256(plan_payload).hexdigest()[:32]
        battery = source.battery
        slot_seconds = source.forecast.slotDurationSeconds
        soc = battery.stateOfChargeWh
        reserve = max(battery.minimumSocWh, source.reserve.backupReserveWh)
        high_price = max(source.tariff.importPriceMicrosPerKwh)
        low_price = min(source.tariff.importPriceMicrosPerKwh)
        slots = []

        for index, (solar, load, price) in enumerate(
            zip(
                source.forecast.solarEnergyWh,
                source.forecast.loadEnergyWh,
                source.tariff.importPriceMicrosPerKwh,
                strict=True,
            )
        ):
            action = "hold"
            power = 0
            reason = "balanced"
            max_charge_wh = battery.maxChargePowerW * slot_seconds // 3_600
            max_discharge_wh = battery.maxDischargePowerW * slot_seconds // 3_600
            if override_status == "active":
                reason = "manual_override"
                requested_wh = override.powerW * slot_seconds // 3_600
                if override.mode == "charge":
                    amount = min(requested_wh, max_charge_wh, battery.maximumSocWh - soc)
                    if amount > 0:
                        action, power = "charge", amount * 3_600 // slot_seconds
                        soc += amount
                elif override.mode == "discharge":
                    amount = min(requested_wh, max_discharge_wh, soc - reserve)
                    if amount > 0:
                        action, power = "discharge", amount * 3_600 // slot_seconds
                        soc -= amount
            else:
                surplus = max(solar - load, 0)
                deficit = max(load - solar, 0)
                if surplus:
                    amount = min(surplus, max_charge_wh, battery.maximumSocWh - soc)
                    if amount > 0:
                        action, power, reason = (
                            "charge",
                            amount * 3_600 // slot_seconds,
                            "solar_surplus",
                        )
                        soc += amount
                    else:
                        reason = "safety_limit"
                elif deficit and price == high_price and high_price > low_price:
                    amount = min(deficit, max_discharge_wh, soc - reserve)
                    if amount > 0:
                        action, power, reason = (
                            "discharge",
                            amount * 3_600 // slot_seconds,
                            "high_tariff_deficit",
                        )
                        soc -= amount
                    else:
                        reason = "safety_limit"
            slots.append(
                EnergyPlanSlot(
                    schemaVersion=1,
                    index=index,
                    startsAtMs=source.forecast.startsAtMs + index * slot_seconds * 1_000,
                    action=action,
                    powerW=power,
                    projectedSocWh=soc,
                    reason=reason,
                )
            )
        return EnergyPlan(
            schemaVersion=1,
            planId=plan_id,
            coreId=source.coreId,
            homeId=source.homeId,
            homeRevision=source.homeRevision,
            batteryId=battery.resourceId,
            batteryRevision=battery.revision,
            batteryProviderRevision=battery.providerRevision,
            meterRevision=source.meter.revision,
            forecastRevision=source.forecast.revision,
            forecastProviderRevision=source.forecast.providerRevision,
            tariffRevision=source.tariff.revision,
            reserveRevision=source.reserve.revision,
            overrideRevision=override.revision if override is not None else None,
            inputDigest=input_digest,
            advisory=True,
            automaticExecutionAllowed=False,
            overrideStatus=override_status,
            overrideExpiresAtMs=(
                override.expiresAtMs if override is not None else None
            ),
            slots=slots,
        )
