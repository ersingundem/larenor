"""Closed revision-bound contracts for solar and battery planning."""

from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision, Snapshot


TimestampMs = Annotated[int, Field(ge=0, le=2**63 - 1)]
EnergyWh = Annotated[int, Field(ge=0, le=10**12)]
PowerW = Annotated[int, Field(ge=0, le=10**9)]
Price = Annotated[int, Field(ge=-10**9, le=10**9)]


class EnergyAuthority(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    accountId: Identity
    accountRevision: Revision
    memberRevision: Revision
    sessionFamilyId: Identity
    role: Literal["admin", "member"]
    active: bool
    canPlan: bool
    canControl: bool


class MeterInput(FrozenModel):
    schemaVersion: Literal[1]
    resourceId: Identity
    revision: Revision
    providerRevision: Revision
    capturedAtMs: TimestampMs


class SolarForecastInput(FrozenModel):
    schemaVersion: Literal[1]
    resourceId: Identity
    revision: Revision
    providerRevision: Revision
    generatedAtMs: TimestampMs
    startsAtMs: TimestampMs
    slotDurationSeconds: int = Field(ge=300, le=3_600)
    solarEnergyWh: list[EnergyWh] = Field(min_length=1, max_length=96)
    loadEnergyWh: list[EnergyWh] = Field(min_length=1, max_length=96)

    @model_validator(mode="after")
    def matching_slots(self):
        if len(self.solarEnergyWh) != len(self.loadEnergyWh):
            raise ValueError("slot_count_mismatch")
        return self


class TariffInput(FrozenModel):
    schemaVersion: Literal[1]
    resourceId: Identity
    revision: Revision
    startsAtMs: TimestampMs
    slotDurationSeconds: int = Field(ge=300, le=3_600)
    importPriceMicrosPerKwh: list[Price] = Field(min_length=1, max_length=96)
    exportPriceMicrosPerKwh: list[Price] = Field(min_length=1, max_length=96)

    @model_validator(mode="after")
    def matching_slots(self):
        if len(self.importPriceMicrosPerKwh) != len(self.exportPriceMicrosPerKwh):
            raise ValueError("slot_count_mismatch")
        return self


class BatteryInput(FrozenModel):
    schemaVersion: Literal[1]
    resourceId: Identity
    revision: Revision
    providerRevision: Revision
    capturedAtMs: TimestampMs
    capacityWh: EnergyWh
    stateOfChargeWh: EnergyWh
    minimumSocWh: EnergyWh
    maximumSocWh: EnergyWh
    maxChargePowerW: PowerW
    maxDischargePowerW: PowerW

    @model_validator(mode="after")
    def safe_limits(self):
        if not (
            0 < self.capacityWh
            and self.minimumSocWh <= self.stateOfChargeWh <= self.maximumSocWh
            and self.minimumSocWh < self.maximumSocWh <= self.capacityWh
            and self.maxChargePowerW > 0
            and self.maxDischargePowerW > 0
        ):
            raise ValueError("invalid_battery_limits")
        return self


class ReservePolicy(FrozenModel):
    schemaVersion: Literal[1]
    revision: Revision
    backupReserveWh: EnergyWh


class ManualOverride(FrozenModel):
    schemaVersion: Literal[1]
    revision: Revision
    mode: Literal["charge", "discharge", "hold"]
    powerW: PowerW
    expiresAtMs: TimestampMs

    @model_validator(mode="after")
    def hold_has_no_power(self):
        if self.mode == "hold" and self.powerW != 0:
            raise ValueError("invalid_override")
        if self.mode != "hold" and self.powerW == 0:
            raise ValueError("invalid_override")
        return self


class EnergyInputs(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    meter: MeterInput
    forecast: SolarForecastInput
    tariff: TariffInput
    battery: BatteryInput
    reserve: ReservePolicy
    manualOverride: ManualOverride | None

    @model_validator(mode="after")
    def coherent_inputs(self):
        count = len(self.forecast.solarEnergyWh)
        if (
            len(self.tariff.importPriceMicrosPerKwh) != count
            or self.tariff.startsAtMs != self.forecast.startsAtMs
            or self.tariff.slotDurationSeconds != self.forecast.slotDurationSeconds
            or self.reserve.backupReserveWh > self.battery.maximumSocWh
        ):
            raise ValueError("input_mismatch")
        return self


class EnergyPlanSlot(FrozenModel):
    schemaVersion: Literal[1]
    index: int = Field(ge=0, le=95)
    startsAtMs: TimestampMs
    action: Literal["charge", "discharge", "hold"]
    powerW: PowerW
    projectedSocWh: EnergyWh
    reason: Literal[
        "solar_surplus",
        "high_tariff_deficit",
        "manual_override",
        "safety_limit",
        "balanced",
    ]


class EnergyPlan(FrozenModel):
    schemaVersion: Literal[1]
    planId: Identity
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    batteryId: Identity
    batteryRevision: Revision
    batteryProviderRevision: Revision
    meterRevision: Revision
    forecastRevision: Revision
    forecastProviderRevision: Revision
    tariffRevision: Revision
    reserveRevision: Revision
    overrideRevision: Revision | None
    inputDigest: Snapshot
    advisory: Literal[True]
    automaticExecutionAllowed: Literal[False]
    overrideStatus: Literal["none", "active", "expired"]
    slots: list[EnergyPlanSlot] = Field(min_length=1, max_length=96)


class InverterCommandPreview(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    planId: Identity
    coreId: Identity
    homeId: Identity
    accountId: Identity
    accountRevision: Revision
    memberRevision: Revision
    sessionFamilyId: Identity
    inverterId: Identity
    expectedInverterRevision: Revision
    batteryId: Identity
    expectedBatteryRevision: Revision
    inputDigest: Snapshot
    targetPowerW: int = Field(ge=-10**9, le=10**9)
    expiresAtMs: TimestampMs
    confirmationToken: Snapshot


class InverterCommand(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    planId: Identity
    coreId: Identity
    homeId: Identity
    accountId: Identity
    accountRevision: Revision
    memberRevision: Revision
    sessionFamilyId: Identity
    inverterId: Identity
    expectedInverterRevision: Revision
    batteryId: Identity
    expectedBatteryRevision: Revision
    inputDigest: Snapshot
    targetPowerW: int = Field(ge=-10**9, le=10**9)


class InverterReadback(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    coreId: Identity
    homeId: Identity
    inverterId: Identity
    inverterRevision: Revision
    batteryId: Identity
    batteryRevision: Revision
    inputDigest: Snapshot
    targetPowerW: int = Field(ge=-10**9, le=10**9)
    observedPowerW: int = Field(ge=-10**9, le=10**9)
    status: Literal["applied"]


class InverterCommandResult(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    status: Literal["confirmed", "uncertain"]
    reason: Literal["lost_ack", "readback_mismatch"] | None
    readbackVerified: bool
    readback: InverterReadback | None

    @model_validator(mode="after")
    def coherent_result(self):
        if self.status == "confirmed":
            if not self.readbackVerified or self.readback is None or self.reason is not None:
                raise ValueError("invalid_result")
        elif self.readbackVerified or self.readback is not None or self.reason is None:
            raise ValueError("invalid_result")
        return self
