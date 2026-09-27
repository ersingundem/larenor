"""Closed, metadata-only contracts for local sound classification."""

from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision, Snapshot

TimestampMs = Annotated[int, Field(ge=0, le=2**63 - 1)]
Confidence = Annotated[float, Field(ge=0.0, le=1.0)]
SoundClass = Literal["bark", "noise"]


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
    allowedClasses: list[SoundClass] = Field(
        default_factory=lambda: ["bark", "noise"], min_length=1, max_length=2
    )
    retentionSeconds: int = Field(ge=60, le=7 * 24 * 60 * 60)
    maxEventDurationMs: int = Field(default=30_000, ge=100, le=60_000)
    observationMaxAgeMs: int = Field(default=30_000, ge=1_000, le=5 * 60_000)
    rawAudioRetention: Literal["never"] = "never"
    triggerConfidence: Confidence
    releaseConfidence: Confidence
    consecutiveTriggerCount: int = Field(ge=1, le=10)
    dedupWindowMs: int = Field(ge=1_000, le=24 * 60 * 60 * 1_000)
    providerStatus: Literal["ready", "degraded"]

    @model_validator(mode="after")
    def valid_hysteresis(self):
        if (self.releaseConfidence >= self.triggerConfidence
                or len(set(self.allowedClasses)) != len(self.allowedClasses)):
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
    className: SoundClass
    confidence: Confidence
    durationMs: int = Field(default=1_000, ge=100, le=60_000)
    observedAtMs: TimestampMs
    evidenceDigest: Snapshot

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
    className: SoundClass
    confidence: Confidence
    durationMs: int = Field(default=1_000, ge=100, le=60_000)
    observedAtMs: TimestampMs
    evidenceDigest: Snapshot
    retentionExpiresAtMs: TimestampMs
    automationVerified: bool

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
    className: SoundClass
    confidence: Confidence
    durationMs: int = Field(default=1_000, ge=100, le=60_000)
    observedAtMs: TimestampMs
    evidenceDigest: Snapshot
    auditSequence: int = Field(ge=1, le=10_000)
    auditHead: Snapshot

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
    reason: (
        Literal[
            "below_threshold",
            "awaiting_confirmation",
            "hysteresis_active",
            "deduplicated",
            "provider_unavailable",
            "automation_unavailable",
            "automation_unverified",
            "observation_stale",
        ]
        | None
    )
    event: SoundEvent | None
    automationVerified: bool

    @model_validator(mode="after")
    def coherent_result(self):
        if self.status == "event":
            if (
                self.event is None
                or not self.automationVerified
                or self.reason is not None
            ):
                raise ValueError("invalid_result")
        elif self.status == "suppressed":
            if self.event is not None or self.automationVerified or self.reason is None:
                raise ValueError("invalid_result")
        elif self.event is None and self.reason not in {
            "provider_unavailable",
            "automation_unavailable",
            "observation_stale",
        }:
            raise ValueError("invalid_result")
        return self


class SoundEventClientAuthority(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    accountId: Identity
    sessionFamilyId: Identity
    accountRevision: Revision
    repositoryRevision: Revision
    canRead: bool
    canAcknowledge: bool


class SoundEventRecord(FrozenModel):
    schemaVersion: Literal[1]
    eventId: Identity
    roomId: Identity
    deviceId: Identity
    className: SoundClass
    confidence: Confidence
    durationMs: int = Field(ge=100, le=60_000)
    observedAtMs: TimestampMs
    retentionExpiresAtMs: TimestampMs
    eventRevision: Revision
    acknowledged: bool
    automationVerified: bool
    feedback: Literal["false_alarm", "confirmed"] | None
    notificationEligible: bool


class SoundEventNotificationPolicy(FrozenModel):
    schemaVersion: Literal[1]
    revision: Revision
    notificationsEnabled: bool
    barkEnabled: bool
    noiseEnabled: bool
    mutedUntilMs: TimestampMs | None
    sourceClipRetention: Literal["never"]


class SoundSourceStatus(FrozenModel):
    schemaVersion: Literal[1]
    state: Literal["ready", "degraded", "stale", "unavailable"]
    capabilityRevision: Revision | None
    providerRevision: Revision | None
    modelRevision: Revision | None
    lastObservationAtMs: TimestampMs | None
    freshnessDeadlineMs: TimestampMs | None
    silenceProven: Literal[False]
    clipAvailable: bool

    @model_validator(mode="after")
    def coherent_status(self):
        revisions = (
            self.capabilityRevision,
            self.providerRevision,
            self.modelRevision,
        )
        if self.state == "unavailable":
            if (any(item is not None for item in revisions)
                    or self.lastObservationAtMs is not None
                    or self.freshnessDeadlineMs is not None
                    or self.clipAvailable):
                raise ValueError("invalid_source_status")
        elif (any(item is None for item in revisions)
                or self.freshnessDeadlineMs is None):
            raise ValueError("invalid_source_status")
        return self


class SoundEventSnapshot(FrozenModel):
    schemaVersion: Literal[2]
    authority: SoundEventClientAuthority
    repositoryRevision: Revision
    policy: SoundEventNotificationPolicy
    sourceStatus: SoundSourceStatus
    events: list[SoundEventRecord] = Field(max_length=100)

    @model_validator(mode="after")
    def exact_revision(self):
        if self.authority.repositoryRevision != self.repositoryRevision:
            raise ValueError("revision_mismatch")
        return self


class SoundEventAcknowledgementRequest(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    expectedRepositoryRevision: Revision
    expectedEventRevision: Revision


class SoundEventAcknowledgement(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    eventId: Identity
    coreId: Identity
    homeId: Identity
    accountId: Identity
    sessionFamilyId: Identity
    repositoryRevision: Revision
    eventRevision: Revision
    acknowledged: Literal[True]


class SoundEventPolicyRequest(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    expectedRepositoryRevision: Revision
    expectedPolicyRevision: Revision
    notificationsEnabled: bool
    barkEnabled: bool
    noiseEnabled: bool
    mutedUntilMs: TimestampMs | None
    sourceClipRetention: Literal["never"]


class SoundEventPolicyReceipt(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    accountId: Identity
    sessionFamilyId: Identity
    repositoryRevision: Revision
    policy: SoundEventNotificationPolicy


class SoundEventFeedbackRequest(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    expectedRepositoryRevision: Revision
    expectedEventRevision: Revision
    classification: Literal["false_alarm", "confirmed"]


class SoundEventFeedbackReceipt(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    eventId: Identity
    accountId: Identity
    sessionFamilyId: Identity
    repositoryRevision: Revision
    eventRevision: Revision
    classification: Literal["false_alarm", "confirmed"]
