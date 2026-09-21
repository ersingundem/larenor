"""Closed contracts for revision-bound irrigation planning and valve effects."""

from typing import Annotated, Literal

from pydantic import Field, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision

TimestampMs = Annotated[int, Field(ge=0, le=2**63 - 1)]


class IrrigationAuthority(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    accountId: Identity
    accountRevision: Revision
    sessionFamilyId: Identity
    role: Literal["admin", "member"]
    active: bool
    canManageIrrigation: bool


class IrrigationZone(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    zoneId: Identity
    zoneRevision: Revision
    areaId: Identity
    areaRevision: Revision
    valveServiceId: Identity
    valveServiceRevision: Revision
    valveBindingId: Identity
    valveBindingRevision: Revision
    flowMlPerMinute: int = Field(ge=1, le=1_000_000)
    maxDurationSeconds: int = Field(ge=1, le=7_200)


class IrrigationPolicy(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    policyId: Identity
    policyRevision: Revision
    zones: list[IrrigationZone] = Field(min_length=1, max_length=32)
    targetMoisturePermille: int = Field(ge=1, le=1_000)
    soilMaxAgeMs: int = Field(ge=1_000, le=24 * 60 * 60 * 1000)
    safetyMaxAgeMs: int = Field(ge=1_000, le=60 * 60 * 1000)
    forecastMaxAgeMs: int = Field(ge=60_000, le=48 * 60 * 60 * 1000)
    rainDeferralMilliMm: int = Field(ge=0, le=1_000_000)
    freezeThresholdMilliC: int = Field(ge=-50_000, le=20_000)
    windLimitMilliMps: int = Field(ge=0, le=100_000)
    previewTtlMs: int = Field(ge=1_000, le=60_000)
    active: bool

    @model_validator(mode="after")
    def unique_zones(self):
        ids = [item.zoneId for item in self.zones]
        bindings = [item.valveBindingId for item in self.zones]
        if len(ids) != len(set(ids)) or len(bindings) != len(set(bindings)):
            raise ValueError("duplicate_zone")
        if any(
            (item.coreId, item.homeId) != (self.coreId, self.homeId)
            for item in self.zones
        ):
            raise ValueError("zone_scope_mismatch")
        return self


class SoilMoistureReading(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    zoneId: Identity
    zoneRevision: Revision
    sensorId: Identity
    sensorRevision: Revision
    readingRevision: Revision
    moisturePermille: int = Field(ge=0, le=1_000)
    observedAtMs: TimestampMs


class IrrigationSafetySnapshot(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    safetyRevision: Revision
    leakDetected: bool
    temperatureMilliC: int = Field(ge=-100_000, le=100_000)
    windMilliMps: int = Field(ge=0, le=200_000)
    observedAtMs: TimestampMs


class RainForecast(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    sourceId: Identity
    sourceRevision: Revision
    forecastRevision: Revision
    generatedAtMs: TimestampMs
    validUntilMs: TimestampMs
    rainMilliMm: int = Field(ge=0, le=10_000_000)

    @model_validator(mode="after")
    def valid_window(self):
        if self.validUntilMs <= self.generatedAtMs:
            raise ValueError("invalid_forecast_window")
        return self


class WaterBudget(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    budgetRevision: Revision
    dayStartMs: TimestampMs
    dailyLimitMl: int = Field(ge=0, le=10_000_000_000)
    usedMl: int = Field(ge=0, le=10_000_000_000)
    priceMicrosPerLiter: int = Field(ge=0, le=1_000_000_000)

    @model_validator(mode="after")
    def valid_usage(self):
        if self.usedMl > self.dailyLimitMl:
            raise ValueError("budget_overdrawn")
        return self


class ManualWaterOverride(FrozenModel):
    schemaVersion: Literal[1]
    overrideId: Identity
    coreId: Identity
    homeId: Identity
    policyId: Identity
    expectedPolicyRevision: Revision
    zoneId: Identity
    expectedZoneRevision: Revision
    actorAccountId: Identity
    durationSeconds: int = Field(ge=1, le=7_200)
    createdAtMs: TimestampMs
    expiresAtMs: TimestampMs

    @model_validator(mode="after")
    def valid_window(self):
        if (
            self.expiresAtMs <= self.createdAtMs
            or self.expiresAtMs - self.createdAtMs > 24 * 60 * 60 * 1000
        ):
            raise ValueError("invalid_override_window")
        return self


class IrrigationInputRevisions(FrozenModel):
    schemaVersion: Literal[1]
    policyRevision: Revision
    safetyRevision: Revision
    forecastRevision: Revision
    budgetRevision: Revision
    forecastSourceId: Identity
    forecastSourceRevision: Revision
    soilSensorIds: dict[Identity, Identity] = Field(min_length=1, max_length=32)
    soilSensorRevisions: dict[Identity, Revision] = Field(min_length=1, max_length=32)
    soilReadingRevisions: dict[Identity, Revision] = Field(min_length=1, max_length=32)


class IrrigationPlanItem(FrozenModel):
    schemaVersion: Literal[1]
    zone: IrrigationZone
    status: Literal["planned", "deferred", "skipped", "blocked"]
    reason: Literal[
        "moisture_deficit",
        "manual_override",
        "rain_forecast",
        "moisture_sufficient",
        "budget_exhausted",
        "leak_detected",
        "freeze_risk",
        "wind_risk",
        "safety_stale",
        "soil_sensor_stale",
    ]
    durationSeconds: int = Field(ge=0, le=7_200)
    estimatedWaterMl: int = Field(ge=0, le=10_000_000_000)


class IrrigationPlan(FrozenModel):
    schemaVersion: Literal[1]
    planId: Identity
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    policyId: Identity
    policyRevision: Revision
    policyHash: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    actorAccountId: Identity
    accountRevision: Revision
    sessionFamilyId: Identity
    generatedAtMs: TimestampMs
    forecastStatus: Literal["available", "stale"]
    inputRevisions: IrrigationInputRevisions
    items: list[IrrigationPlanItem] = Field(min_length=1, max_length=32)
    totalWaterMl: int = Field(ge=0, le=10_000_000_000)
    estimatedCostMicros: int = Field(ge=0, le=2**63 - 1)


class ValveReadback(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    zone: IrrigationZone
    stateRevision: Revision
    valveOpen: bool
    observedAtMs: TimestampMs


class ValveWorkerCommand(FrozenModel):
    schemaVersion: Literal[1]
    commandId: Identity
    requestId: Identity
    planId: Identity
    policyRevision: Revision
    actorAccountId: Identity
    zone: IrrigationZone
    expectedStateRevision: Revision
    durationSeconds: int = Field(ge=1, le=7_200)
    expectedWaterMl: int = Field(ge=1, le=10_000_000_000)


class WorkerValveReadback(FrozenModel):
    schemaVersion: Literal[1]
    commandId: Identity
    zone: IrrigationZone
    stateRevision: Revision
    valveOpen: bool
    deliveredMl: int = Field(ge=0, le=10_000_000_000)
    flowVerified: bool
    observedAtMs: TimestampMs


class IrrigationPreview(FrozenModel):
    schemaVersion: Literal[1]
    previewId: Identity
    confirmToken: str = Field(
        min_length=43, max_length=43, pattern=r"^[A-Za-z0-9_-]{43}$"
    )
    requestId: Identity
    planId: Identity
    policyRevision: Revision
    expiresAtMs: TimestampMs
    commandCount: int = Field(ge=1, le=32)


class ValveCommandResult(FrozenModel):
    schemaVersion: Literal[1]
    commandId: Identity
    zoneId: Identity
    status: Literal["applied", "failed", "unknown"]
    code: Literal[
        "applied",
        "flow_not_verified",
        "flow_out_of_bounds",
        "readback_mismatch",
        "worker_ack_unknown",
    ]
    readback: WorkerValveReadback | None


class IrrigationReceipt(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    planId: Identity
    status: Literal["applied", "partial", "failed", "unknown"]
    results: list[ValveCommandResult] = Field(min_length=1, max_length=32)
    completedAtMs: TimestampMs


class IrrigationAuditEvent(FrozenModel):
    schemaVersion: Literal[1]
    sequence: int = Field(ge=1, le=16_384)
    kind: Literal["plan", "preview", "result"]
    coreId: Identity
    homeId: Identity
    policyId: Identity
    policyRevision: Revision
    actorAccountId: Identity
    requestId: Identity
    status: str = Field(min_length=1, max_length=40, pattern=r"^[a-z_]+$")
    payloadHash: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    atMs: TimestampMs
    previousHash: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    entryHash: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
