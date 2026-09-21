"""Closed contracts for privacy-scoped camera metadata search."""

from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision


SafeText = Annotated[str, Field(min_length=1, max_length=240)]
TimestampMs = Annotated[int, Field(ge=0, le=2**63 - 1)]


def safe_text(value: str) -> str:
    if any(
        ord(char) < 32
        or 127 <= ord(char) <= 159
        or 0xD800 <= ord(char) <= 0xDFFF
        or 0x202A <= ord(char) <= 0x202E
        or 0x2066 <= ord(char) <= 0x2069
        or ord(char) == 0xFEFF
        for char in value
    ):
        raise ValueError("unsafe_text")
    value = value.strip()
    if not value:
        raise ValueError("unsafe_text")
    return value


class CameraSearchAuthority(FrozenModel):
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
    allowPrivateEvidence: bool
    active: bool
    canSearch: bool

    @field_validator("accessibleCameraIds")
    @classmethod
    def unique_cameras(cls, value):
        if len(value) != len(set(value)):
            raise ValueError("duplicate_camera")
        return value

    @model_validator(mode="after")
    def private_requires_admin(self):
        if self.allowPrivateEvidence and self.role != "admin":
            raise ValueError("private_requires_admin")
        return self


class CameraMetadataRecord(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    clipId: Identity
    eventId: Identity
    cameraId: Identity
    captureRevision: Revision
    startMs: TimestampMs
    endMs: TimestampMs
    evidenceOffsetMs: Annotated[int, Field(ge=0, le=24 * 60 * 60 * 1000)]
    visibility: Literal["household", "private"]
    ownerAccountId: Identity | None
    labels: list[SafeText] = Field(max_length=32)
    summary: SafeText

    _summary = field_validator("summary")(safe_text)

    @field_validator("labels")
    @classmethod
    def safe_unique_labels(cls, value):
        cleaned = [safe_text(item) for item in value]
        if len(cleaned) != len(set(cleaned)):
            raise ValueError("duplicate_label")
        return cleaned

    @model_validator(mode="after")
    def valid_capture(self):
        if self.endMs <= self.startMs or self.evidenceOffsetMs > self.endMs - self.startMs:
            raise ValueError("invalid_capture_window")
        if (self.visibility == "private") != (self.ownerAccountId is not None):
            raise ValueError("invalid_visibility")
        return self


class CameraSearchRequest(FrozenModel):
    schemaVersion: Literal[1]
    query: str = Field(min_length=2, max_length=200)
    expectedIndexRevision: Revision
    startMs: TimestampMs
    endMs: TimestampMs
    cameraIds: list[Identity] = Field(min_length=1, max_length=16)
    pageSize: int = Field(ge=1, le=50)
    cursor: str | None = Field(default=None, min_length=40, max_length=512,
                               pattern=r"^[A-Za-z0-9_.-]+$")

    _query = field_validator("query")(safe_text)

    @field_validator("cameraIds")
    @classmethod
    def unique_cameras(cls, value):
        if len(value) != len(set(value)):
            raise ValueError("duplicate_camera")
        return value

    @model_validator(mode="after")
    def bounded_window(self):
        if self.endMs <= self.startMs or self.endMs - self.startMs > 31 * 24 * 60 * 60 * 1000:
            raise ValueError("invalid_time_window")
        return self


class CameraEvidenceLink(FrozenModel):
    schemaVersion: Literal[1]
    kind: Literal["camera_evidence"]
    coreId: Identity
    homeId: Identity
    cameraId: Identity
    clipId: Identity
    eventId: Identity
    captureRevision: Revision
    indexRevision: Revision
    capturedAtMs: TimestampMs


class CameraSearchMatch(FrozenModel):
    schemaVersion: Literal[1]
    startMs: TimestampMs
    endMs: TimestampMs
    summary: SafeText
    matchedTerms: list[SafeText] = Field(min_length=1, max_length=16)
    evidence: CameraEvidenceLink


class CameraSearchPage(FrozenModel):
    schemaVersion: Literal[1]
    indexRevision: Revision
    mode: Literal["local_metadata", "semantic_assisted"]
    status: Literal["ready", "degraded"]
    degradedReason: Literal["semantic_provider_unavailable"] | None
    results: list[CameraSearchMatch] = Field(max_length=50)
    nextCursor: str | None = Field(default=None, max_length=512)

    @model_validator(mode="after")
    def status_reason_pair(self):
        if (self.status == "degraded") != (self.degradedReason is not None):
            raise ValueError("invalid_status")
        if self.status == "ready" and self.mode != "semantic_assisted":
            raise ValueError("invalid_status")
        return self
