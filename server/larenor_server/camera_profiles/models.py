"""Closed contracts for presence-informed camera recording profiles."""

from typing import Annotated, Literal

from pydantic import Field, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision


TimestampMs = Annotated[int, Field(ge=0, le=2**63 - 1)]


class CameraMode(FrozenModel):
    recording: Literal["enabled", "paused"]
    detection: Literal["enabled", "disabled"]


class CameraProfileAuthority(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    accountId: Identity
    accountRevision: Revision
    sessionFamilyId: Identity
    role: Literal["admin", "member"]
    active: bool
    canManageCameraProfiles: bool


class CameraScope(FrozenModel):
    schemaVersion: Literal[1]
    cameraId: Identity
    cameraRevision: Revision
    areaId: Identity
    areaRevision: Revision
    serviceId: Identity
    serviceRevision: Revision
    bindingId: Identity
    bindingRevision: Revision


class CameraProfilePolicy(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    profileId: Identity
    profileRevision: Revision
    presenceSourceId: Identity
    presenceSourceRevision: Revision
    cameras: list[CameraScope] = Field(min_length=1, max_length=64)
    enterDelayMs: int = Field(ge=0, le=60 * 60 * 1000)
    exitDelayMs: int = Field(ge=0, le=60 * 60 * 1000)
    hysteresisMs: int = Field(ge=0, le=15 * 60 * 1000)
    presenceMaxAgeMs: int = Field(ge=1_000, le=24 * 60 * 60 * 1000)
    atHomeMode: CameraMode
    awayMode: CameraMode
    failSafeMode: CameraMode
    active: bool

    @model_validator(mode="after")
    def valid_policy(self):
        camera_ids = [item.cameraId for item in self.cameras]
        binding_ids = [item.bindingId for item in self.cameras]
        if len(camera_ids) != len(set(camera_ids)) or len(binding_ids) != len(
            set(binding_ids)
        ):
            raise ValueError("duplicate_camera_scope")
        if self.failSafeMode.recording != "enabled":
            raise ValueError("unsafe_fail_safe_mode")
        return self


class PresenceSignal(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    sourceId: Identity
    sourceRevision: Revision
    signalRevision: Revision
    observedAtMs: TimestampMs
    state: Literal["home", "away", "unknown"]


class ManualCameraOverride(FrozenModel):
    schemaVersion: Literal[1]
    overrideId: Identity
    coreId: Identity
    homeId: Identity
    profileId: Identity
    expectedProfileRevision: Revision
    actorAccountId: Identity
    mode: CameraMode
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


class CameraDesiredState(FrozenModel):
    schemaVersion: Literal[1]
    camera: CameraScope
    mode: CameraMode


class CameraProfileDecision(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    profileId: Identity
    profileRevision: Revision
    policyHash: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    actorAccountId: Identity
    accountRevision: Revision
    sessionFamilyId: Identity
    presenceSourceId: Identity
    presenceSourceRevision: Revision
    signalRevision: Revision
    evaluatedAtMs: TimestampMs
    reason: Literal[
        "presence_home",
        "presence_away",
        "presence_unknown",
        "presence_stale",
        "presence_stabilizing",
        "manual_override",
        "manual_override_expired",
    ]
    mode: CameraMode
    targets: list[CameraDesiredState] = Field(min_length=1, max_length=64)


class CameraReadback(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    camera: CameraScope
    stateRevision: Revision
    mode: CameraMode
    observedAtMs: TimestampMs


class CameraWorkerCommand(FrozenModel):
    schemaVersion: Literal[1]
    commandId: Identity
    requestId: Identity
    coreId: Identity
    homeId: Identity
    profileId: Identity
    profileRevision: Revision
    actorAccountId: Identity
    camera: CameraScope
    expectedStateRevision: Revision
    desiredMode: CameraMode


class WorkerReadback(FrozenModel):
    schemaVersion: Literal[1]
    commandId: Identity
    camera: CameraScope
    stateRevision: Revision
    mode: CameraMode
    observedAtMs: TimestampMs


class CameraCommandResult(FrozenModel):
    schemaVersion: Literal[1]
    commandId: Identity
    cameraId: Identity
    status: Literal["applied", "skipped", "failed", "unknown"]
    code: Literal[
        "applied",
        "already_applied",
        "readback_mismatch",
        "worker_ack_unknown",
        "worker_response_invalid",
    ]
    readback: WorkerReadback | None


class CameraCommandReceipt(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    profileId: Identity
    profileRevision: Revision
    status: Literal["applied", "already_applied", "partial", "failed", "unknown"]
    results: list[CameraCommandResult] = Field(min_length=1, max_length=64)
    createdAtMs: TimestampMs


class CameraAuditEvent(FrozenModel):
    schemaVersion: Literal[1]
    sequence: int = Field(ge=1, le=16_384)
    kind: Literal["decision", "command_batch", "result"]
    coreId: Identity
    homeId: Identity
    profileId: Identity
    profileRevision: Revision
    actorAccountId: Identity
    requestId: Identity
    status: str = Field(min_length=1, max_length=40, pattern=r"^[a-z_]+$")
    payloadHash: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    atMs: TimestampMs
    previousHash: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    entryHash: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
