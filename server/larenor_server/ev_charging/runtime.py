from dataclasses import dataclass, replace
from typing import Protocol

from ..errors import ApiError
from .service import (
    ChargeAuthority,
    ChargeGoal,
    ChargePlanner,
    EnergyInputs,
)


@dataclass(frozen=True)
class ChargeDeviceCapability:
    charger_id: str
    label: str
    charger_revision: int
    schedule_revision: int
    tariff_revision: int
    power_budget_revision: int
    current_soc: int
    battery_capacity_wh: int
    max_current_amp: int

    def __post_init__(self):
        if (
            len(self.charger_id) != 32
            or any(value not in "0123456789abcdef" for value in self.charger_id)
            or not self.label.strip()
            or self.label != self.label.strip()
            or len(self.label) > 80
            or any(ord(value) < 32 or ord(value) == 127 for value in self.label)
            or any(
                type(value) is not int or value < 1
                for value in (
                    self.charger_revision,
                    self.schedule_revision,
                    self.tariff_revision,
                    self.power_budget_revision,
                )
            )
            or not 0 <= self.current_soc <= 100
            or not 1 <= self.battery_capacity_wh <= 500_000
            or not 1 <= self.max_current_amp <= 80
        ):
            raise ValueError("invalid_ev_charge_device_capability")


@dataclass(frozen=True)
class ChargeProviderCapability:
    state: str
    provider_kind: str
    can_plan: bool
    can_control: bool
    reason: str
    chargers: tuple[ChargeDeviceCapability, ...] = ()

    def __post_init__(self):
        if (
            self.state not in {"ready", "degraded", "unavailable"}
            or self.provider_kind not in {"ocpp", "vehicle_api", "manual", "none"}
            or type(self.can_plan) is not bool
            or type(self.can_control) is not bool
            or self.reason
            not in {
                "ready",
                "provider_not_configured",
                "provider_unreachable",
                "charger_read_only",
            }
            or (self.state != "ready" and (self.can_plan or self.can_control))
            or (self.state == "ready" and not self.can_plan)
            or (self.can_control and not self.can_plan)
            or (self.can_plan and not self.chargers)
            or len(self.chargers) > 16
            or len({item.charger_id for item in self.chargers}) != len(self.chargers)
            or (self.state != "ready" and self.chargers)
        ):
            raise ValueError("invalid_ev_charge_capability")


@dataclass(frozen=True)
class ChargeProviderSnapshot:
    authority: ChargeAuthority
    inputs: EnergyInputs


class ChargeStateProvider(Protocol):
    def capability(self) -> ChargeProviderCapability: ...

    def snapshot(
        self, *, actor_id: str, session_family_id: str, charger_id: str
    ) -> ChargeProviderSnapshot: ...


class UnavailableCharger:
    def apply(self, *, plan_hash: str, slots: tuple[dict, ...]) -> None:
        raise ConnectionError("charger_provider_unavailable")

    def readback(self) -> str | None:
        return None


class EvChargeRuntime:
    """Authenticated adapter around trusted provider facts and the durable planner."""

    def __init__(self, db, auth, settings, key, context, provider, charger):
        self.db, self.auth, self.settings = db, auth, settings
        self.core_id, self.home_id = context.coreId, context.homeId
        self.provider: ChargeStateProvider | None = provider
        self.control_available = charger is not None
        self.planner = ChargePlanner(
            db,
            audit_key=key,
            charger=charger or UnavailableCharger(),
            clock=settings.clock,
        )

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.core_id, self.home_id):
            raise ApiError("not_found", 404)

    def _actor(self, actor):
        with self.db.connection() as connection:
            self.auth.assert_current(connection, actor)
            row = connection.execute(
                "SELECT disabled,must_change_password FROM users WHERE id=?",
                (actor.id,),
            ).fetchone()
            if row is None or row["disabled"] or row["must_change_password"]:
                raise ApiError("forbidden", 403)

    def capability(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        self._actor(actor)
        if self.provider is None:
            value = ChargeProviderCapability(
                "unavailable", "none", False, False, "provider_not_configured"
            )
        else:
            try:
                value = self.provider.capability()
            except Exception:
                value = ChargeProviderCapability(
                    "unavailable", "none", False, False, "provider_unreachable"
                )
        if not isinstance(value, ChargeProviderCapability):
            raise ApiError("ev_charge_provider_invalid", 503)
        if value.can_control and not self.control_available:
            value = replace(value, can_control=False, reason="charger_read_only")
        self._actor(actor)
        return {
            "schemaVersion": 1,
            "coreId": self.core_id,
            "homeId": self.home_id,
            "state": value.state,
            "providerKind": value.provider_kind,
            "canPlan": value.can_plan,
            "canControl": value.can_control,
            "reason": value.reason,
            "chargers": [
                {
                    "schemaVersion": 1,
                    "chargerId": item.charger_id,
                    "label": item.label,
                    "chargerRevision": item.charger_revision,
                    "scheduleRevision": item.schedule_revision,
                    "tariffRevision": item.tariff_revision,
                    "powerBudgetRevision": item.power_budget_revision,
                    "currentSoc": item.current_soc,
                    "batteryCapacityWh": item.battery_capacity_wh,
                    "maxCurrentAmp": item.max_current_amp,
                }
                for item in value.chargers
            ],
        }

    def _snapshot(self, actor, core_id, home_id, charger_id, *, control=False):
        self._scope(core_id, home_id)
        self._actor(actor)
        if self.provider is None:
            raise ApiError("ev_charge_provider_unavailable", 503)
        try:
            capability = self.provider.capability()
            snapshot = self.provider.snapshot(
                actor_id=actor.id,
                session_family_id=actor.family_id,
                charger_id=charger_id,
            )
        except ApiError:
            raise
        except Exception:
            raise ApiError("ev_charge_provider_unavailable", 503) from None
        if (
            not isinstance(capability, ChargeProviderCapability)
            or not isinstance(snapshot, ChargeProviderSnapshot)
            or capability.state != "ready"
            or not capability.can_plan
            or (control and not self.control_available)
            or (control and not capability.can_control)
        ):
            raise ApiError("ev_charge_provider_unavailable", 503)
        devices = [
            item for item in capability.chargers if item.charger_id == charger_id
        ]
        if len(devices) != 1:
            raise ApiError("ev_charge_provider_unavailable", 503)
        device = devices[0]
        authority = snapshot.authority
        if (
            authority.core_id != self.core_id
            or authority.home_id != self.home_id
            or authority.charger_id != charger_id
            or authority.account_id != actor.id
            or authority.session_id != actor.family_id
            or authority.charger_revision != device.charger_revision
            or authority.schedule_revision != device.schedule_revision
            or authority.tariff_revision != device.tariff_revision
            or authority.power_budget_revision != device.power_budget_revision
            or authority.max_current_amp != device.max_current_amp
        ):
            raise ApiError("energy_authority_changed", 409)
        self._actor(actor)
        return snapshot, device

    @staticmethod
    def _preview(value, authority):
        return {
            "schemaVersion": 1,
            "coreId": authority.core_id,
            "homeId": authority.home_id,
            "chargerId": authority.charger_id,
            "accountId": authority.account_id,
            "sessionFamilyId": authority.session_id,
            "chargerRevision": authority.charger_revision,
            "scheduleRevision": value.schedule_revision,
            "tariffRevision": authority.tariff_revision,
            "powerBudgetRevision": authority.power_budget_revision,
            "previewId": value.id,
            "planHash": value.plan_hash,
            "status": value.status,
            "requiredWh": value.required_wh,
            "providerStatus": value.provider_status,
            "overrideExpiresAtMs": None
            if value.override_expires_at is None
            else round(value.override_expires_at * 1000),
            "slots": [
                {
                    "startAtMs": round(slot.start_at * 1000),
                    "endAtMs": round(slot.end_at * 1000),
                    "currentAmp": slot.current_amp,
                    "energyWh": slot.energy_wh,
                    "tariffMicrosPerKwh": slot.tariff_micros_per_kwh,
                    "solarSurplusW": slot.solar_surplus_w,
                }
                for slot in value.slots
            ],
        }

    def preview(self, actor, core_id, home_id, charger_id, body):
        snapshot, device = self._snapshot(actor, core_id, home_id, charger_id)
        authority = snapshot.authority
        expected = (
            body.expectedChargerRevision,
            body.expectedScheduleRevision,
            body.expectedTariffRevision,
            body.expectedPowerBudgetRevision,
        )
        actual = (
            authority.charger_revision,
            authority.schedule_revision,
            authority.tariff_revision,
            authority.power_budget_revision,
        )
        if expected != actual:
            raise ApiError("energy_authority_changed", 409)
        value = self.planner.preview(
            actor,
            authority=authority,
            inputs=snapshot.inputs,
            goal=ChargeGoal(
                departure_at=body.departureAtMs / 1000,
                current_soc=device.current_soc,
                minimum_soc=device.current_soc,
                target_soc=body.targetSoc,
                battery_capacity_wh=device.battery_capacity_wh,
                max_current_amp=device.max_current_amp,
            ),
            preview_id=body.previewId,
        )
        return {"schemaVersion": 1, "preview": self._preview(value, authority)}

    def confirm(self, actor, core_id, home_id, charger_id, body):
        snapshot, _device = self._snapshot(
            actor, core_id, home_id, charger_id, control=True
        )
        authority = snapshot.authority
        if (
            body.expectedChargerRevision != authority.charger_revision
            or body.expectedScheduleRevision != authority.schedule_revision
        ):
            raise ApiError("energy_authority_changed", 409)
        value = self.planner.confirm(
            actor,
            authority=authority,
            preview_id=body.previewId,
            command_id=body.commandId,
            expected_plan_hash=body.expectedPlanHash,
        )
        return {"schemaVersion": 1, "receipt": self._receipt(value, authority)}

    @staticmethod
    def _receipt(value, authority):
        return {
            "schemaVersion": 1,
            "coreId": authority.core_id,
            "homeId": authority.home_id,
            "chargerId": authority.charger_id,
            "accountId": authority.account_id,
            "sessionFamilyId": authority.session_id,
            "chargerRevision": authority.charger_revision,
            "scheduleRevision": authority.schedule_revision,
            "commandId": value.command_id,
            "previewId": value.preview_id,
            "planHash": value.plan_hash,
            "status": value.status,
            "applyCount": value.apply_count,
        }
