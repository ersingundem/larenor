from typing import Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel


class Versioned(StrictModel):
    schemaVersion: Literal[1] = 1

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def exact_version(cls, value):
        if type(value) is not int:
            raise ValueError("live_tv_schema_unsupported")
        return value


class EpgProgramme(Versioned):
    programmeId: ObjectId
    channelId: ObjectId
    channelName: str = Field(min_length=1, max_length=120)
    title: str = Field(min_length=1, max_length=240)
    startsAt: int = Field(ge=1, le=253402300799)
    endsAt: int = Field(ge=2, le=253402300799)

    @field_validator("channelName", "title")
    @classmethod
    def safe_text(cls, value):
        if value != value.strip() or any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ValueError("invalid_live_tv_text")
        return value

    @model_validator(mode="after")
    def coherent(self):
        if self.startsAt >= self.endsAt or self.endsAt - self.startsAt > 86_400:
            raise ValueError("invalid_live_tv_programme")
        return self


class SourceSnapshotRequest(Versioned):
    requestId: ObjectId
    expectedRevision: int = Field(ge=0, le=2**63 - 1)
    providerId: str = Field(min_length=1, max_length=128)
    providerKind: Literal["tuner", "iptv"]
    providerRevision: Revision
    timeZone: str = Field(min_length=1, max_length=64)
    parallelTuners: int = Field(ge=1, le=8)
    quotaBytes: int = Field(ge=1_073_741_824, le=10_995_116_277_760)
    capturedAt: int = Field(ge=1, le=253402300799)
    programmes: list[EpgProgramme] = Field(max_length=2048)

    @field_validator("providerId")
    @classmethod
    def provider_identity(cls, value):
        if value != value.strip() or any(
                not (c.isalnum() or c in "-_.:") for c in value):
            raise ValueError("invalid_live_tv_provider")
        return value

    @field_validator("timeZone")
    @classmethod
    def time_zone(cls, value):
        try:
            ZoneInfo(value)
        except ZoneInfoNotFoundError:
            raise ValueError("invalid_live_tv_timezone") from None
        return value

    @model_validator(mode="after")
    def bounded_epg(self):
        if len({item.programmeId for item in self.programmes}) != len(self.programmes):
            raise ValueError("duplicate_live_tv_programme")
        ordered = sorted(self.programmes, key=lambda item: (item.channelId, item.startsAt))
        for first, second in zip(ordered, ordered[1:]):
            if first.channelId == second.channelId and first.endsAt > second.startsAt:
                raise ValueError("overlapping_live_tv_epg")
        return self


class RecordingRequest(Versioned):
    requestId: ObjectId
    expectedSourceRevision: Revision
    expectedProviderRevision: Revision
    programmeId: ObjectId


class RecordingMutationRequest(Versioned):
    requestId: ObjectId
    expectedRevision: Revision


class RecordingInterruptionRequest(RecordingMutationRequest):
    bytesWritten: int = Field(ge=0, le=10_995_116_277_760)
    providerRevision: Revision
    readbackRevision: Revision


class LiveTvAuthority(Versioned):
    coreId: ObjectId
    homeId: ObjectId
    accountId: ObjectId
    accountRevision: Revision
    sessionFamilyId: ObjectId
    sourceRevision: Revision
    providerRevision: Revision


class Recording(Versioned):
    recordingId: ObjectId
    revision: Revision
    providerRevision: Revision
    readbackRevision: Revision
    programmeId: ObjectId
    channelId: ObjectId
    channelName: str
    title: str
    startsAt: int
    endsAt: int
    state: Literal[
        "scheduled", "recording", "interrupted", "completed", "cancelled",
        "partial", "uncertain",
    ]
    bytesWritten: int = Field(ge=0, le=10_995_116_277_760)
    restartCount: int = Field(ge=0, le=16)


class LiveTvSnapshot(Versioned):
    authority: LiveTvAuthority
    providerId: str
    providerKind: Literal["tuner", "iptv"]
    timeZone: str
    parallelTuners: int
    quotaBytes: int
    usedBytes: int
    capturedAt: int
    programmes: list[EpgProgramme] = Field(max_length=2048)
    recordings: list[Recording] = Field(max_length=256)


class LiveTvSnapshotResponse(Versioned):
    snapshot: LiveTvSnapshot


class RecordingResponse(Versioned):
    recording: Recording
