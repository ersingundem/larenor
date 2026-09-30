"""Closed revision-bound contracts for solar and battery planning."""

from typing import Annotated, Literal

from pydantic import Field, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision, Snapshot

TimestampMs = Annotated[int, Field(ge=0, le=2**63 - 1)]
EnergyWh = Annotated[int, Field(ge=0, le=10**12)]
PowerW = Annotated[int, Field(ge=0, le=10**9)]
Price = Annotated[int, Field(ge=-(10**9), le=10**9)]


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
    gridImportPowerW: PowerW
    gridExportPowerW: PowerW

    @model_validator(mode="after")
    def single_grid_direction(self):
        if self.gridImportPowerW and self.gridExportPowerW:
            raise ValueError("invalid_meter_direction")
        return self


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
    backupReservePercent: Annotated[int, Field(ge=0, le=100)]


class InverterCapability(FrozenModel):
    schemaVersion: Literal[1]
    inverterId: Identity
    revision: Revision
    canCharge: bool
    canDischarge: bool
    writable: bool
    physicalAcceptance: Literal["manual"]
    canSetReserve: bool = False
    controlSemantics: Literal["exact_power", "reserve_percent", "none"] = (
        "exact_power"
    )

    @model_validator(mode="after")
    def coherent_controls(self):
        if self.controlSemantics == "reserve_percent":
            if not self.canSetReserve or self.canCharge or self.canDischarge:
                raise ValueError("invalid_inverter_capability")
        elif self.controlSemantics == "none":
            if self.writable or self.canSetReserve:
                raise ValueError("invalid_inverter_capability")
        elif self.canSetReserve:
            raise ValueError("invalid_inverter_capability")
        return self


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
    overrideExpiresAtMs: TimestampMs | None
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
    targetPowerW: int = Field(ge=-(10**9), le=10**9)
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
    targetPowerW: int = Field(ge=-(10**9), le=10**9)


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
    targetPowerW: int = Field(ge=-(10**9), le=10**9)
    observedPowerW: int = Field(ge=-(10**9), le=10**9)
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
            if (
                not self.readbackVerified
                or self.readback is None
                or self.reason is not None
            ):
                raise ValueError("invalid_result")
        elif self.readbackVerified or self.readback is not None or self.reason is None:
            raise ValueError("invalid_result")
        return self


class ReserveCommandPreview(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    coreId: Identity
    homeId: Identity
    accountId: Identity
    accountRevision: Revision
    memberRevision: Revision
    sessionFamilyId: Identity
    inverterId: Identity
    inverterRevision: Revision
    batteryId: Identity
    batteryRevision: Revision
    batteryProviderRevision: Revision
    inputDigest: Snapshot
    targetReservePercent: Annotated[int, Field(ge=0, le=100)]
    expiresAtMs: TimestampMs
    confirmationToken: Snapshot


class ReserveCommandResult(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    status: Literal["confirmed", "uncertain", "mismatch"]
    targetReservePercent: Annotated[int, Field(ge=0, le=100)]
    observedReservePercent: Annotated[int, Field(ge=0, le=100)] | None
    bindingRevision: Revision

    @model_validator(mode="after")
    def coherent_reserve_result(self):
        if self.status == "confirmed":
            if self.observedReservePercent != self.targetReservePercent:
                raise ValueError("invalid_reserve_result")
        elif self.status == "uncertain":
            if self.observedReservePercent is not None:
                raise ValueError("invalid_reserve_result")
        elif self.observedReservePercent is None:
            raise ValueError("invalid_reserve_result")
        return self


class ReserveBacktestSlot(FrozenModel):
    schemaVersion: Literal[1]
    startsAtMs: TimestampMs
    endsAtMs: TimestampMs
    observedSocPercent: float | None = Field(default=None, ge=0, le=100)
    forecastRecorded: bool
    status: Literal["above_or_equal", "below", "missing"]

    @model_validator(mode="after")
    def coherent_slot(self):
        if self.endsAtMs - self.startsAtMs != 3_600_000:
            raise ValueError("invalid_backtest_slot")
        if (self.observedSocPercent is None) != (self.status == "missing"):
            raise ValueError("invalid_backtest_slot")
        return self


class ReserveBacktestResult(FrozenModel):
    schemaVersion: Literal[1]
    analysisDigest: Snapshot
    authority: EnergyAuthority
    serviceId: Identity
    serviceRevision: Revision
    batteryId: Identity
    batteryRevision: Revision
    batteryProviderRevision: Revision
    reserveRevision: Revision
    reservePercent: Annotated[int, Field(ge=0, le=100)]
    capacityWh: Annotated[int, Field(ge=1, le=10**12)]
    historyDigest: Snapshot
    capturedAtMs: TimestampMs
    startsAtMs: TimestampMs
    endsAtMs: TimestampMs
    slotDurationSeconds: Literal[3600]
    expectedSampleCount: Literal[168]
    sampleCount: int = Field(ge=0, le=168)
    missingSampleCount: int = Field(ge=0, le=168)
    belowReserveSampleCount: int = Field(ge=0, le=168)
    forecastRecordCount: int = Field(ge=0, le=168)
    minimumObservedSocPercent: float | None = Field(default=None, ge=0, le=100)
    observedStatus: Literal[
        "no_sample_below_reserve", "sample_below_reserve", "uncertain"
    ]
    sampleCoverage: Literal["complete", "partial", "missing"]
    forecastCoverage: Literal["complete", "partial", "missing"]
    manualPreference: Literal["none_current", "active_current", "expired_current"]
    historicalPreferenceCoverage: Literal["unavailable"]
    historicalCapacityCoverage: Literal["unavailable"]
    historicalReservePolicyCoverage: Literal["unavailable"]
    uncertaintyReasons: list[Literal[
        "missing_battery_history",
        "partial_battery_history",
        "multiple_battery_series",
        "missing_forecast_history",
        "partial_forecast_history",
        "historical_preferences_unavailable",
        "historical_capacity_unavailable",
        "historical_reserve_policy_unavailable",
        "current_manual_preference",
    ]] = Field(min_length=1, max_length=9)
    slots: list[ReserveBacktestSlot] = Field(min_length=168, max_length=168)

    @model_validator(mode="after")
    def coherent_backtest(self):
        if (
            self.endsAtMs - self.startsAtMs != 168 * 3_600_000
            or not self.endsAtMs <= self.capturedAtMs < self.endsAtMs + 3_600_000
            or self.sampleCount + self.missingSampleCount != 168
            or self.belowReserveSampleCount > self.sampleCount
            or len({slot.startsAtMs for slot in self.slots}) != 168
            or self.slots[0].startsAtMs != self.startsAtMs
            or self.slots[-1].endsAtMs != self.endsAtMs
            or any(
                current.startsAtMs != previous.endsAtMs
                for previous, current in zip(self.slots, self.slots[1:])
            )
            or len(set(self.uncertaintyReasons)) != len(self.uncertaintyReasons)
        ):
            raise ValueError("invalid_backtest")
        observed = [
            slot.observedSocPercent
            for slot in self.slots
            if slot.observedSocPercent is not None
        ]
        if (
            len(observed) != self.sampleCount
            or sum(value < self.reservePercent for value in observed)
            != self.belowReserveSampleCount
            or (min(observed) if observed else None)
            != self.minimumObservedSocPercent
        ):
            raise ValueError("invalid_backtest")
        expected_status = (
            "sample_below_reserve"
            if self.belowReserveSampleCount
            else "no_sample_below_reserve"
            if self.sampleCoverage == "complete"
            else "uncertain"
        )
        expected_coverage = (
            "missing"
            if self.sampleCount == 0
            else "complete"
            if self.sampleCount == 168
            else "partial"
        )
        expected_forecast_coverage = (
            "missing"
            if self.forecastRecordCount == 0
            else "complete"
            if self.forecastRecordCount == 168
            else "partial"
        )
        if (
            self.observedStatus != expected_status
            or self.sampleCoverage != expected_coverage
            or self.forecastCoverage != expected_forecast_coverage
        ):
            raise ValueError("invalid_backtest")
        return self
