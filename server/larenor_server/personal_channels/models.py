"""Strict versioned contracts for personal television channels."""

from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from ..plugins.media_playback_models import PrivateMediaPlaybackAuthority


def _exact_version(value):
    if type(value) is not int:
        raise ValueError("invalid_schema")
    return value


class Versioned(StrictModel):
    schemaVersion: Literal[1] = 1

    _version = field_validator("schemaVersion", mode="before")(_exact_version)


class ChannelSource(Versioned):
    installationId: ObjectId
    expectedInstallationRevision: Revision
    expectedSnapshotRevision: Revision
    expectedJellyfinServiceRevision: Revision
    itemId: ObjectId
    mediaKey: str = Field(min_length=1, max_length=96)
    title: str = Field(min_length=1, max_length=240)
    durationSeconds: int = Field(ge=60, le=86_400)

    @field_validator("title")
    @classmethod
    def safe_title(cls, value):
        if value != value.strip() or any(
                ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid_channel_title")
        return value

    def playback_request(self, request_id):
        return {
            "requestId": request_id,
            "installationId": self.installationId,
            "expectedInstallationRevision": self.expectedInstallationRevision,
            "expectedSnapshotRevision": self.expectedSnapshotRevision,
            "expectedJellyfinServiceRevision": self.expectedJellyfinServiceRevision,
            "itemId": self.itemId,
            "mediaKey": self.mediaKey,
        }


class CreateChannelRequest(Versioned):
    requestId: ObjectId
    name: str = Field(min_length=1, max_length=80)
    startsAt: int = Field(ge=1, le=253402300799)
    loop: bool = True
    sources: list[ChannelSource] = Field(min_length=1, max_length=64)

    @field_validator("name")
    @classmethod
    def safe_name(cls, value):
        if value != value.strip() or any(
                ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid_channel_name")
        return value

    @model_validator(mode="after")
    def bounded_cycle(self):
        if sum(source.durationSeconds for source in self.sources) > 604_800:
            raise ValueError("personal_channel_cycle_too_long")
        return self


class ExpectedChannelRequest(Versioned):
    requestId: ObjectId
    expectedRevision: Revision


class RescheduleProgrammeRequest(ExpectedChannelRequest):
    expectedProgrammeRevision: Revision
    source: ChannelSource


class ResolveProgrammeRequest(Versioned):
    expectedChannelRevision: Revision
    expectedProgrammeRevision: Revision
    programmeId: ObjectId
    occurrenceStartsAt: int = Field(ge=1, le=253402300799)
    mode: Literal["live", "restart"]


class ChannelAuthority(Versioned):
    coreId: ObjectId
    homeId: ObjectId
    accountId: ObjectId
    accountRevision: Revision
    sessionFamilyId: ObjectId


class Programme(Versioned):
    programmeId: ObjectId
    revision: Revision
    position: int = Field(ge=0, le=63)
    title: str = Field(min_length=1, max_length=240)
    itemId: ObjectId | None
    mediaKey: str | None = Field(default=None, min_length=1, max_length=96)
    occurrenceStartsAt: int = Field(ge=1, le=253402300799)
    occurrenceEndsAt: int = Field(ge=2, le=253402300799)
    state: Literal["scheduled", "gap"]
    reason: Literal["available", "deleted", "unreachable"]
    canRestart: bool

    @model_validator(mode="after")
    def coherent(self):
        if (self.occurrenceStartsAt >= self.occurrenceEndsAt
                or (self.state == "scheduled") != (self.reason == "available")
                or self.canRestart != (self.state == "scheduled")
                or (self.state == "scheduled") != (self.itemId is not None)
                or (self.state == "scheduled") != (self.mediaKey is not None)):
            raise ValueError("invalid_channel_programme")
        return self


class ChannelSnapshot(Versioned):
    channelId: ObjectId
    authority: ChannelAuthority
    revision: Revision
    name: str = Field(min_length=1, max_length=80)
    state: Literal["active", "cancelled"]
    startsAt: int = Field(ge=1, le=253402300799)
    loop: bool
    cycleSeconds: int = Field(ge=60, le=604_800)
    guideFrom: int = Field(ge=1, le=253402300799)
    guideUntil: int = Field(ge=2, le=253402300799)
    programmes: list[Programme] = Field(max_length=64)

    @model_validator(mode="after")
    def coherent(self):
        if (self.guideFrom >= self.guideUntil
                or len({(item.programmeId, item.occurrenceStartsAt)
                        for item in self.programmes}) != len(self.programmes)
                or any(first.occurrenceEndsAt > second.occurrenceStartsAt
                       for first, second in zip(
                           self.programmes, self.programmes[1:]))):
            raise ValueError("invalid_personal_channel")
        return self


class ChannelSnapshotResponse(StrictModel):
    channel: ChannelSnapshot


class ChannelListResponse(Versioned):
    channels: list[ChannelSnapshot] = Field(max_length=16)


class PlaybackSource(Versioned):
    channelId: ObjectId
    channelRevision: Revision
    programmeId: ObjectId
    programmeRevision: Revision
    occurrenceStartsAt: int = Field(ge=1, le=253402300799)
    startSeconds: int = Field(ge=0, le=86_400)
    authority: PrivateMediaPlaybackAuthority


class PlaybackSourceResponse(StrictModel):
    playback: PlaybackSource
