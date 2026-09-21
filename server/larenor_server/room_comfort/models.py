"""Closed contracts for room comfort planning and device effects."""

from typing import Annotated, Literal

from pydantic import Field, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision


TimestampMs = Annotated[int, Field(ge=0, le=2**63 - 1)]
DeviceState = Literal["off", "heat", "cool", "ventilate", "closed", "open"]


class ComfortAuthority(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    accountId: Identity
    accountRevision: Revision
    sessionFamilyId: Identity
    role: Literal["admin", "member"]
    active: bool
    canManageComfort: bool


class ComfortDevice(FrozenModel):
    schemaVersion: Literal[1]
    kind: Literal["hvac", "window"]
    deviceId: Identity
    deviceRevision: Revision
    serviceId: Identity
    serviceRevision: Revision
    bindingId: Identity
    bindingRevision: Revision


class RoomComfortScope(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    roomId: Identity
    roomRevision: Revision
    areaId: Identity
    areaRevision: Revision
    hvac: ComfortDevice
    window: ComfortDevice

    @model_validator(mode="after")
    def correct_devices(self):
        if self.hvac.kind != "hvac" or self.window.kind != "window":
            raise ValueError("device_kind_mismatch")
        if self.hvac.deviceId == self.window.deviceId or self.hvac.bindingId == self.window.bindingId:
            raise ValueError("duplicate_device")
        return self


class ComfortPolicy(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    policyId: Identity
    policyRevision: Revision
    rooms: list[RoomComfortScope] = Field(min_length=1, max_length=32)
    targetTemperatureMilliC: int = Field(ge=5_000, le=35_000)
    temperatureToleranceMilliC: int = Field(ge=100, le=10_000)
    humidityHighPermille: int = Field(ge=1, le=1_000)
    co2HighPpm: int = Field(ge=400, le=10_000)
    vocHighPpb: int = Field(ge=1, le=100_000)
    outdoorAqiLimit: int = Field(ge=1, le=500)
    freezeThresholdMilliC: int = Field(ge=-50_000, le=15_000)
    indoorMaxAgeMs: int = Field(ge=1_000, le=24 * 60 * 60 * 1000)
    outdoorMaxAgeMs: int = Field(ge=1_000, le=24 * 60 * 60 * 1000)
    occupancyMaxAgeMs: int = Field(ge=1_000, le=24 * 60 * 60 * 1000)
    previewTtlMs: int = Field(ge=1_000, le=60_000)
    active: bool

    @model_validator(mode="after")
    def unique_rooms(self):
        rooms = [item.roomId for item in self.rooms]
        devices = [device.deviceId for item in self.rooms for device in (item.hvac, item.window)]
        if len(rooms) != len(set(rooms)) or len(devices) != len(set(devices)):
            raise ValueError("duplicate_room")
        if any((item.coreId, item.homeId) != (self.coreId, self.homeId) for item in self.rooms):
            raise ValueError("room_scope_mismatch")
        return self


class MetricReading(FrozenModel):
    schemaVersion: Literal[1]
    kind: Literal["temperature_millic", "humidity_permille", "co2_ppm", "voc_ppb"]
    sensorId: Identity
    sensorRevision: Revision
    readingRevision: Revision
    value: int = Field(ge=-100_000, le=1_000_000)
    observedAtMs: TimestampMs


class RoomClimateSnapshot(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    roomId: Identity
    roomRevision: Revision
    snapshotRevision: Revision
    temperature: MetricReading
    humidity: MetricReading
    co2: MetricReading
    voc: MetricReading
    smokeDetected: bool
    smokeSensorId: Identity
    smokeSensorRevision: Revision
    smokeReadingRevision: Revision
    smokeObservedAtMs: TimestampMs

    @model_validator(mode="after")
    def valid_metrics(self):
        if [self.temperature.kind, self.humidity.kind, self.co2.kind, self.voc.kind] != [
            "temperature_millic", "humidity_permille", "co2_ppm", "voc_ppb"
        ]:
            raise ValueError("metric_kind_mismatch")
        if (not -50_000 <= self.temperature.value <= 80_000
                or not 0 <= self.humidity.value <= 1_000
                or not 0 <= self.co2.value <= 100_000
                or not 0 <= self.voc.value <= 1_000_000):
            raise ValueError("metric_out_of_range")
        ids = [item.sensorId for item in (self.temperature, self.humidity, self.co2, self.voc)]
        if len(ids) != len(set(ids)) or self.smokeSensorId in ids:
            raise ValueError("duplicate_sensor")
        return self


class OutdoorWeatherSnapshot(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    sourceId: Identity
    sourceRevision: Revision
    weatherRevision: Revision
    temperatureMilliC: int = Field(ge=-100_000, le=100_000)
    raining: bool
    airQualityIndex: int = Field(ge=0, le=500)
    observedAtMs: TimestampMs


class OccupancySnapshot(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    roomId: Identity
    roomRevision: Revision
    sourceId: Identity
    sourceRevision: Revision
    occupancyRevision: Revision
    occupied: bool
    observedAtMs: TimestampMs


class ManualComfortOverride(FrozenModel):
    schemaVersion: Literal[1]
    overrideId: Identity
    coreId: Identity
    homeId: Identity
    policyId: Identity
    expectedPolicyRevision: Revision
    roomId: Identity
    expectedRoomRevision: Revision
    actorAccountId: Identity
    hvacMode: Literal["off", "heat", "cool", "ventilate"]
    windowState: Literal["closed", "open"]
    createdAtMs: TimestampMs
    expiresAtMs: TimestampMs

    @model_validator(mode="after")
    def valid_window(self):
        if self.expiresAtMs <= self.createdAtMs or self.expiresAtMs - self.createdAtMs > 24 * 60 * 60 * 1000:
            raise ValueError("invalid_override_window")
        if self.windowState == "open" and self.hvacMode != "off":
            raise ValueError("unsafe_override")
        return self


class ComfortInputRevisions(FrozenModel):
    schemaVersion: Literal[1]
    policyRevision: Revision
    weatherRevision: Revision
    weatherSourceId: Identity
    weatherSourceRevision: Revision
    roomSnapshotRevisions: dict[Identity, Revision] = Field(min_length=1, max_length=32)
    occupancyRevisions: dict[Identity, Revision] = Field(min_length=1, max_length=32)
    occupancySourceIds: dict[Identity, Identity] = Field(min_length=1, max_length=32)
    occupancySourceRevisions: dict[Identity, Revision] = Field(min_length=1, max_length=32)
    metricSensorRevisions: dict[Identity, dict[str, Revision]] = Field(min_length=1, max_length=32)
    metricReadingRevisions: dict[Identity, dict[str, Revision]] = Field(min_length=1, max_length=32)
    smokeSensorRevisions: dict[Identity, Revision] = Field(min_length=1, max_length=32)
    smokeReadingRevisions: dict[Identity, Revision] = Field(min_length=1, max_length=32)


class ComfortPlanItem(FrozenModel):
    schemaVersion: Literal[1]
    room: RoomComfortScope
    status: Literal["planned", "skipped", "blocked"]
    reason: Literal[
        "air_refresh", "temperature_low", "temperature_high", "comfortable",
        "manual_override", "sensor_stale", "smoke_detected", "freeze_risk",
        "rain_window_block", "outdoor_air_unsafe",
    ]
    hvacMode: Literal["off", "heat", "cool", "ventilate"]
    windowState: Literal["closed", "open"]


class ComfortPlan(FrozenModel):
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
    inputRevisions: ComfortInputRevisions
    occupancyAdvisory: dict[Identity, Literal["occupied", "unoccupied", "stale"]]
    items: list[ComfortPlanItem] = Field(min_length=1, max_length=32)


class ComfortDeviceReadback(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    roomId: Identity
    device: ComfortDevice
    stateRevision: Revision
    state: DeviceState
    observedAtMs: TimestampMs

    @model_validator(mode="after")
    def state_matches_device(self):
        if (self.device.kind == "hvac" and self.state in ("open", "closed")) or (
            self.device.kind == "window" and self.state not in ("open", "closed")
        ):
            raise ValueError("state_kind_mismatch")
        return self


class ComfortWorkerCommand(FrozenModel):
    schemaVersion: Literal[1]
    commandId: Identity
    requestId: Identity
    planId: Identity
    policyRevision: Revision
    actorAccountId: Identity
    roomId: Identity
    targetKind: Literal["hvac", "window"]
    device: ComfortDevice
    expectedStateRevision: Revision
    desiredState: DeviceState


class WorkerComfortReadback(FrozenModel):
    schemaVersion: Literal[1]
    commandId: Identity
    roomId: Identity
    device: ComfortDevice
    stateRevision: Revision
    state: DeviceState
    observedAtMs: TimestampMs


class ComfortPreview(FrozenModel):
    schemaVersion: Literal[1]
    previewId: Identity
    confirmToken: str = Field(min_length=43, max_length=43, pattern=r"^[A-Za-z0-9_-]{43}$")
    requestId: Identity
    planId: Identity
    expiresAtMs: TimestampMs
    commandCount: int = Field(ge=1, le=64)


class ComfortCommandResult(FrozenModel):
    schemaVersion: Literal[1]
    commandId: Identity
    roomId: Identity
    targetKind: Literal["hvac", "window"]
    status: Literal["applied", "failed", "unknown"]
    code: Literal["applied", "readback_mismatch", "worker_ack_unknown"]
    readback: WorkerComfortReadback | None


class ComfortReceipt(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    planId: Identity
    status: Literal["applied", "partial", "failed", "unknown"]
    results: list[ComfortCommandResult] = Field(min_length=1, max_length=64)
    completedAtMs: TimestampMs


class ComfortAuditEvent(FrozenModel):
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
