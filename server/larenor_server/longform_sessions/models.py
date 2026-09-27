"""Strict public contracts for audiobook and podcast listening sessions."""

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
    schemaVersion: Literal[1] = 1
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
    bookmarks: list[LongformBookmark] = Field(default_factory=list,
                                               max_length=64)

    @model_validator(mode="after")
    def unique_bookmarks(self):
        if (len({item.bookmarkId for item in self.bookmarks})
                != len(self.bookmarks)):
            raise ValueError("invalid_longform_bookmark")
        return self


class LongformSession(Versioned):
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
        return self


class LongformSessionResponse(StrictModel):
    session: LongformSession
