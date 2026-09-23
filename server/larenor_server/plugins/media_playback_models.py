"""Strict public and private contracts for managed media playback."""

import re
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel

_TARGET = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}\Z')
_MEDIA_KEY = re.compile(
    r'(?:movie:tmdb:[1-9][0-9]{0,11}|episode:tvdb:[1-9][0-9]{0,11}:'
    r'[0-9]{1,4}:[0-9]{1,5})\Z'
)


class MediaPlaybackTarget(StrictModel):
    targetId: str = Field(min_length=1, max_length=128)
    targetRevision: Revision
    name: str = Field(min_length=1, max_length=128)
    available: bool
    currentItemId: ObjectId | None
    positionSeconds: int = Field(ge=0, le=8640000)

    @model_validator(mode='after')
    def coherent(self):
        if (_TARGET.fullmatch(self.targetId) is None
                or self.name != self.name.strip()
                or any(ord(char) < 32 or ord(char) == 127
                       for char in self.name)):
            raise ValueError('invalid_media_playback_target')
        return self


class MediaPlaybackReadback(StrictModel):
    playbackRevision: Revision
    targets: list[MediaPlaybackTarget] = Field(min_length=1, max_length=64)

    @model_validator(mode='after')
    def unique_targets(self):
        if len({item.targetId for item in self.targets}) != len(self.targets):
            raise ValueError('invalid_media_playback_readback')
        return self


class PrepareMediaPlaybackIntentRequest(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    expectedSnapshotRevision: Revision
    expectedJellyfinServiceRevision: Revision
    itemId: ObjectId
    mediaKey: str = Field(min_length=1, max_length=96)

    @field_validator('mediaKey')
    @classmethod
    def media_key(cls, value):
        if _MEDIA_KEY.fullmatch(value) is None:
            raise ValueError('invalid_media_playback_item')
        return value


class MediaPlaybackIntent(PrepareMediaPlaybackIntentRequest):
    playbackRevision: Revision
    expiresAt: int = Field(ge=1, le=253402300799)
    targets: list[MediaPlaybackTarget] = Field(min_length=1, max_length=64)


class MediaPlaybackIntentResponse(StrictModel):
    intent: MediaPlaybackIntent


class MediaPlaybackCommandRequest(StrictModel):
    requestId: ObjectId
    intentId: ObjectId
    expectedPlaybackRevision: Revision
    targetId: str = Field(min_length=1, max_length=128)
    expectedTargetRevision: Revision
    startSeconds: int = Field(ge=0, le=8640000)

    @field_validator('targetId')
    @classmethod
    def target_id(cls, value):
        if _TARGET.fullmatch(value) is None:
            raise ValueError('invalid_media_playback_target')
        return value


class MediaPlaybackReceipt(StrictModel):
    requestId: ObjectId
    intentId: ObjectId
    installationId: ObjectId
    itemId: ObjectId
    targetId: str = Field(min_length=1, max_length=128)
    playbackRevision: Revision
    state: Literal['succeeded', 'needs_attention']
    code: Literal['authenticated_readback', 'effect_unknown']
    installAvailable: Literal[False] = False


class MediaPlaybackReceiptResponse(StrictModel):
    receipt: MediaPlaybackReceipt


class PrivateMediaPlaybackAuthority(StrictModel):
    installationId: ObjectId
    installationRevision: Revision
    snapshotRevision: Revision
    jellyfinServiceRevision: Revision
    itemId: ObjectId
    mediaKey: str = Field(min_length=1, max_length=96)


class PrivateMediaPlaybackAction(StrictModel):
    requestId: ObjectId
    intentId: ObjectId
    installationId: ObjectId
    installationRevision: Revision
    snapshotRevision: Revision
    jellyfinServiceRevision: Revision
    itemId: ObjectId
    mediaKey: str = Field(min_length=1, max_length=96)
    expectedPlaybackRevision: Revision
    targetId: str = Field(min_length=1, max_length=128)
    expectedTargetRevision: Revision
    startSeconds: int = Field(ge=0, le=8640000)


class MediaPlaybackWorkerResult(StrictModel):
    state: Literal['succeeded']
    playbackRevision: Revision
    target: MediaPlaybackTarget
