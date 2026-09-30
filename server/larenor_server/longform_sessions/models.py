"""Strict public contracts for audiobook and podcast listening sessions."""

import re
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from ..plugins.music_playback_models import ReadMusicLongformRequest


def _exact_version(value):
    if type(value) is not int:
        raise ValueError("invalid_schema")
    return value


class Versioned(StrictModel):
    schemaVersion: Literal[1] = 1
    _version = field_validator("schemaVersion", mode="before")(_exact_version)


class LongformSleepTarget(StrictModel):
    targetId: str = Field(min_length=1, max_length=128)
    expectedProvider: str = Field(min_length=1, max_length=128)
    expectedTargetKind: Literal[
        "homepod", "airplay", "airplay_group", "cast", "cast_group",
        "group", "other",
    ]
    expectedQueueId: str = Field(min_length=1, max_length=128)
    expectedGroupMembers: list[str] = Field(max_length=64)

    @field_validator(
        "targetId", "expectedProvider", "expectedQueueId",
    )
    @classmethod
    def safe_binding(cls, value):
        if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}", value) is None:
            raise ValueError("invalid_sleep_timer_target")
        return value

    @field_validator("expectedGroupMembers")
    @classmethod
    def safe_members(cls, value):
        if (len(set(value)) != len(value)
                or any(re.fullmatch(
                    r"[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}", item
                ) is None for item in value)):
            raise ValueError("invalid_sleep_timer_target")
        return value

    @model_validator(mode="after")
    def coherent(self):
        grouped = self.expectedTargetKind in {"airplay_group", "group"}
        if grouped != bool(self.expectedGroupMembers):
            raise ValueError("invalid_sleep_timer_target")
        return self


class LongformBookmark(Versioned):
    bookmarkId: ObjectId
    positionSeconds: float = Field(ge=0, le=8640000)
    label: str = Field(min_length=1, max_length=80)

    @model_validator(mode="after")
    def coherent(self):
        if (self.label != self.label.strip()
                or any(ord(char) < 32 or ord(char) == 127
                       for char in self.label)):
            raise ValueError("invalid_longform_bookmark")
        return self


class OpenLongformSessionRequest(ReadMusicLongformRequest):
    schemaVersion: Literal[2] = 2
    mediaUri: str = Field(min_length=1, max_length=2048)
    providerInstanceId: str = Field(min_length=1, max_length=128)
    takeover: bool = False
    _version = field_validator("schemaVersion", mode="before")(_exact_version)


class UpdateLongformSessionRequest(OpenLongformSessionRequest):
    expectedRevision: Revision
    positionSeconds: float = Field(ge=0, le=8640000)
    playbackState: Literal["paused", "playing", "ended"]
    sleepTimerEndsAt: int | None = Field(default=None, ge=1,
                                          le=253402300799)
    sleepTimerTarget: LongformSleepTarget | None = None
    bookmarks: list[LongformBookmark] = Field(default_factory=list,
                                               max_length=64)

    @model_validator(mode="after")
    def unique_bookmarks(self):
        if (len({item.bookmarkId for item in self.bookmarks})
                != len(self.bookmarks)):
            raise ValueError("invalid_longform_bookmark")
        return self


class LongformSession(Versioned):
    schemaVersion: Literal[2] = 2
    sessionId: ObjectId
    revision: Revision
    coreId: ObjectId
    homeId: ObjectId
    accountId: ObjectId
    installationId: ObjectId
    installationRevision: Revision
    coreRevision: Revision
    managerRevision: Revision
    providerInstanceId: str = Field(min_length=1, max_length=128)
    mediaUri: str = Field(min_length=1, max_length=2048, repr=False)
    mediaType: Literal["audiobook", "podcast_episode"]
    title: str = Field(min_length=1, max_length=512)
    durationSeconds: float = Field(gt=0, le=8640000)
    positionSeconds: float = Field(ge=0, le=8640000)
    playbackState: Literal["paused", "playing", "ended"]
    sleepTimerEndsAt: int | None = Field(default=None, ge=1,
                                          le=253402300799)
    sleepTimerState: Literal[
        "off", "scheduled", "enforced", "needs_attention", "cancelled",
    ]
    sleepTimerCode: Literal[
        "scheduled", "authenticated_readback", "effect_unknown",
        "authority_retired", "cancelled",
    ] | None = None
    sleepTimerTargetId: str | None = Field(default=None, max_length=128)
    bookmarks: list[LongformBookmark] = Field(max_length=64)
    ownedByCurrentSession: bool
    updatedAt: int = Field(ge=0, le=253402300799)

    @model_validator(mode="after")
    def coherent(self):
        if (self.positionSeconds > self.durationSeconds
                or self.playbackState == "ended"
                and self.positionSeconds != self.durationSeconds
                or any(item.positionSeconds > self.durationSeconds
                       for item in self.bookmarks)):
            raise ValueError("invalid_longform_session")
        active = self.sleepTimerState == "scheduled"
        if (active != (self.sleepTimerEndsAt is not None)
                or active != (self.sleepTimerTargetId is not None)
                or (self.sleepTimerState == "off") !=
                (self.sleepTimerCode is None)):
            raise ValueError("invalid_longform_session")
        codes = {
            "scheduled": "scheduled",
            "enforced": "authenticated_readback",
            "needs_attention": "effect_unknown",
            "cancelled": "cancelled",
        }
        if (self.sleepTimerState != "off"
                and codes[self.sleepTimerState] != self.sleepTimerCode
                and not (self.sleepTimerState == "cancelled"
                         and self.sleepTimerCode == "authority_retired")):
            raise ValueError("invalid_longform_session")
        return self


class LongformSessionResponse(StrictModel):
    session: LongformSession
