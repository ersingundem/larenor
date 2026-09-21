"""Closed models for camera-derived sensors without raw image data."""

from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision


TimestampMs = Annotated[int, Field(ge=0, le=2**63 - 1)]
Digest = Annotated[str, Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")]


def _safe_label(value: str) -> str:
    if any(
        ord(char) < 32
        or 127 <= ord(char) <= 159
        or 0xD800 <= ord(char) <= 0xDFFF
        or 0x202A <= ord(char) <= 0x202E
        or 0x2066 <= ord(char) <= 0x2069
        or ord(char) == 0xFEFF
        for char in value
    ):
        raise ValueError("unsafe_label")
    value = value.strip()
    if not value:
        raise ValueError("unsafe_label")
    return value


class CameraVisualAuthority(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    accountId: Identity
    accountRevision: Revision
    memberRevision: Revision
    sessionFamilyId: Identity
    role: Literal["admin", "member"]
    accessibleCameraIds: list[Identity] = Field(min_length=1, max_length=64)
    active: bool
    canManageVisualSensors: bool

    @field_validator("accessibleCameraIds")
    @classmethod
    def unique_cameras(cls, value):
        if len(value) != len(set(value)):
            raise ValueError("duplicate_camera")
        return value


class VisualSensorRule(FrozenModel):
    schemaVersion: Literal[1]
    ruleId: Identity
    ruleRevision: Revision
    cameraId: Identity
    pipelineId: Identity
    pipelineRevision: Revision
    modelId: Identity
    modelRevision: Revision
    label: str = Field(min_length=1, max_length=80)
    minimumConfidenceBps: int = Field(ge=1, le=10_000)
    holdForMs: int = Field(ge=0, le=60_000)
    clearAfterMs: int = Field(ge=0, le=300_000)
    evidenceRetentionMs: int = Field(ge=1_000, le=86_400_000)
    enabled: bool

    _label = field_validator("label")(_safe_label)


class EvidenceDescriptor(FrozenModel):
    schemaVersion: Literal[1]
    digest: Digest
    byteLength: int = Field(ge=1, le=25 * 1024 * 1024)
    mediaType: Literal["image/jpeg", "image/png", "image/webp"]
    expiresAtMs: TimestampMs


class Detection(FrozenModel):
    schemaVersion: Literal[1]
    label: str = Field(min_length=1, max_length=80)
    confidenceBps: int = Field(ge=0, le=10_000)
    count: int = Field(ge=1, le=1_000)

    _label = field_validator("label")(_safe_label)


class DetectionBatch(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    cameraId: Identity
    captureRevision: Revision
    pipelineId: Identity
    pipelineRevision: Revision
    modelId: Identity
    modelRevision: Revision
    capturedAtMs: TimestampMs
    providerStatus: Literal["ready", "degraded"]
    frameStatus: Literal["complete", "missing", "corrupt", "wrong_camera"]
    evidence: EvidenceDescriptor
    detections: list[Detection] = Field(max_length=64)

    @model_validator(mode="after")
    def unique_labels(self):
        labels = [item.label for item in self.detections]
        if len(labels) != len(set(labels)):
            raise ValueError("duplicate_detection")
        if self.frameStatus != "complete" and (
            self.providerStatus != "degraded" or self.detections
        ):
            raise ValueError("untrusted_frame")
        return self


class VisualSensorReading(FrozenModel):
    schemaVersion: Literal[1]
    ruleId: Identity
    ruleRevision: Revision
    cameraId: Identity
    state: Literal["on", "off", "unknown"]
    status: Literal["ready", "degraded"]
    transition: Literal[
        "holding_on",
        "activated",
        "stable_on",
        "holding_off",
        "cleared",
        "stable_off",
        "provider_degraded",
    ]
    automationEligible: bool
    sequence: Revision
    observedAtMs: TimestampMs
    captureRevision: Revision
    evidenceDigest: Digest
    confidenceBps: int = Field(ge=0, le=10_000)
    count: int = Field(ge=0, le=1_000)
