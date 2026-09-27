"""Strict public and private contracts for managed media playback."""

import re
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from .stack_plan import MediaStackPlan

_TARGET = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}\Z')
_MEDIA_KEY = re.compile(
    r'(?:movie:tmdb:[1-9][0-9]{0,11}|episode:tvdb:[1-9][0-9]{0,11}:'
    r'[0-9]{1,4}:[0-9]{1,5})\Z'
)
_QUALITY_TOKEN = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.+,\-]{0,63}\Z')


class MediaPlaybackSourceStreamEvidence(StrictModel):
    container: str | None
    bitrate: int | None = Field(default=None, ge=1, le=1_000_000_000)
    videoCodecs: list[str] = Field(max_length=8)
    audioCodecs: list[str] = Field(max_length=8)
    videoRanges: list[str] = Field(max_length=8)

    @model_validator(mode='after')
    def coherent(self):
        values = [self.container, *self.videoCodecs, *self.audioCodecs,
                  *self.videoRanges]
        if (any(value is not None
                and _QUALITY_TOKEN.fullmatch(value) is None for value in values)
                or any(len(items) != len(set(items)) for items in (
                    self.videoCodecs, self.audioCodecs, self.videoRanges))):
            raise ValueError('invalid_media_playback_stream_evidence')
        return self


class MediaPlaybackTranscodingEvidence(StrictModel):
    container: str | None
    videoCodec: str | None
    audioCodec: str | None
    bitrate: int | None = Field(default=None, ge=1, le=1_000_000_000)
    reasons: list[str] = Field(max_length=16)

    @model_validator(mode='after')
    def coherent(self):
        values = [self.container, self.videoCodec, self.audioCodec,
                  *self.reasons]
        if (any(value is not None
                and _QUALITY_TOKEN.fullmatch(value) is None for value in values)
                or len(self.reasons) != len(set(self.reasons))):
            raise ValueError('invalid_media_playback_transcoding_evidence')
        return self


class MediaPlaybackQualityObservation(StrictModel):
    schemaVersion: Literal[1] = 1
    itemId: ObjectId
    playMethod: Literal[
        'unknown', 'direct_play', 'direct_stream', 'transcode'
    ]
    source: MediaPlaybackSourceStreamEvidence
    transcoding: MediaPlaybackTranscodingEvidence | None


class MediaPlaybackTarget(StrictModel):
    targetId: str = Field(min_length=1, max_length=128)
    targetRevision: Revision
    name: str = Field(min_length=1, max_length=128)
    available: bool
    currentItemId: ObjectId | None
    positionSeconds: int = Field(ge=0, le=8640000)
    qualityObservation: MediaPlaybackQualityObservation | None = None

    @model_validator(mode='after')
    def coherent(self):
        if (_TARGET.fullmatch(self.targetId) is None
                or self.name != self.name.strip()
                or any(ord(char) < 32 or ord(char) == 127
                       for char in self.name)
                or (self.qualityObservation is not None
                    and self.qualityObservation.itemId != self.currentItemId)):
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


class PrivateJellyfinPlaybackAuthority(StrictModel):
    authority: PrivateMediaPlaybackAuthority
    plan: MediaStackPlan = Field(repr=False)
    apiKey: str = Field(min_length=32, max_length=128, repr=False)


class PrivateJellyfinPlaybackAction(StrictModel):
    action: PrivateMediaPlaybackAction
    plan: MediaStackPlan = Field(repr=False)
    apiKey: str = Field(min_length=32, max_length=128, repr=False)
