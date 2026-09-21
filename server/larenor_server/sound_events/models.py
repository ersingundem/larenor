"""Closed, metadata-only contracts for local sound classification."""

from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision, Snapshot


TimestampMs = Annotated[int, Field(ge=0, le=2**63 - 1)]
Confidence = Annotated[float, Field(ge=0.0, le=1.0)]


def _safe_label(value: str) -> str:
    value = value.strip()
    if not value or any(
        ord(char) < 32
        or 127 <= ord(char) <= 159
        or 0xD800 <= ord(char) <= 0xDFFF
        or 0x202A <= ord(char) <= 0x202E
        or 0x2066 <= ord(char) <= 0x2069
        or ord(char) == 0xFEFF
        for char in value
    ):
        raise ValueError("unsafe_label")
    return value


class SoundEventAuthority(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    accountId: Identity
    accountRevision: Revision
    memberRevision: Revision
    sessionFamilyId: Identity
    accessibleRoomIds: list[Identity] = Field(min_length=1, max_length=128)
    accessibleDeviceIds: list[Identity] = Field(min_length=1, max_length=128)
    active: bool
    canObserve: bool

    @field_validator("accessibleRoomIds", "accessibleDeviceIds")
    @classmethod
    def unique_ids(cls, value):
        if len(value) != len(set(value)):
            raise ValueError("duplicate_id")
        return value


class SoundClassifierBinding(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    roomId: Identity
    roomRevision: Revision
    deviceId: Identity
    deviceRevision: Revision
    modelId: Identity
    modelRevision: Revision
    providerRevision: Revision
    policyRevision: Revision
    consentRevision: Revision
    consentGranted: bool
    retentionSeconds: int = Field(ge=60, le=7 * 24 * 60 * 60)
    triggerConfidence: Confidence
    releaseConfidence: Confidence
    consecutiveTriggerCount: int = Field(ge=1, le=10)
    dedupWindowMs: int = Field(ge=1_000, le=24 * 60 * 60 * 1_000)
    providerStatus: Literal["ready", "degraded"]

    @model_validator(mode="after")
    def valid_hysteresis(self):
        if self.releaseConfidence >= self.triggerConfidence:
            raise ValueError("invalid_hysteresis")
        return self


class SoundObservation(FrozenModel):
    """A classifier result. Raw audio has no field and extra input is rejected."""

    schemaVersion: Literal[1]
    observationId: Identity
    coreId: Identity
    homeId: Identity
    roomId: Identity
    roomRevision: Revision
    deviceId: Identity
    deviceRevision: Revision
    modelId: Identity
    modelRevision: Revision
    providerRevision: Revision
    policyRevision: Revision
    consentRevision: Revision
    className: str = Field(min_length=1, max_length=48)
    confidence: Confidence
    observedAtMs: TimestampMs
    evidenceDigest: Snapshot

    _class_name = field_validator("className")(_safe_label)


class SoundEvent(FrozenModel):
    schemaVersion: Literal[1]
    eventId: Identity
    coreId: Identity
    homeId: Identity
    roomId: Identity
    roomRevision: Revision
    deviceId: Identity
    deviceRevision: Revision
    modelId: Identity
    modelRevision: Revision
    providerRevision: Revision
    policyRevision: Revision
    consentRevision: Revision
    className: str = Field(min_length=1, max_length=48)
    confidence: Confidence
    observedAtMs: TimestampMs
    evidenceDigest: Snapshot
    retentionExpiresAtMs: TimestampMs
    automationVerified: bool

    _class_name = field_validator("className")(_safe_label)


class AutomationSoundTrigger(FrozenModel):
    schemaVersion: Literal[1]
    eventId: Identity
    coreId: Identity
    homeId: Identity
    roomId: Identity
    roomRevision: Revision
    deviceId: Identity
    deviceRevision: Revision
    modelId: Identity
    modelRevision: Revision
    providerRevision: Revision
    policyRevision: Revision
    consentRevision: Revision
    className: str = Field(min_length=1, max_length=48)
    confidence: Confidence
    observedAtMs: TimestampMs
    evidenceDigest: Snapshot
    auditSequence: int = Field(ge=1, le=10_000)
    auditHead: Snapshot

    _class_name = field_validator("className")(_safe_label)


class AutomationReceipt(FrozenModel):
    schemaVersion: Literal[1]
    eventId: Identity
    coreId: Identity
    homeId: Identity
    roomRevision: Revision
    deviceRevision: Revision
    modelRevision: Revision
    providerRevision: Revision
    policyRevision: Revision
    consentRevision: Revision
    auditSequence: int = Field(ge=1, le=10_000)
    auditHead: Snapshot
    accepted: bool


class SoundIngestResult(FrozenModel):
    schemaVersion: Literal[1]
    status: Literal["suppressed", "event", "degraded"]
    reason: Literal[
        "below_threshold",
        "awaiting_confirmation",
        "hysteresis_active",
        "deduplicated",
        "provider_unavailable",
        "automation_unavailable",
        "automation_unverified",
    ] | None
    event: SoundEvent | None
    automationVerified: bool

    @model_validator(mode="after")
    def coherent_result(self):
        if self.status == "event":
            if self.event is None or not self.automationVerified or self.reason is not None:
                raise ValueError("invalid_result")
        elif self.status == "suppressed":
            if self.event is not None or self.automationVerified or self.reason is None:
                raise ValueError("invalid_result")
        elif self.event is None and self.reason not in {
            "provider_unavailable",
            "automation_unavailable",
        }:
            raise ValueError("invalid_result")
        return self
