"""Secret-free, revision-complete Music Assistant playback effect envelope."""

from typing import Literal

from pydantic import Field, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from .music_playback_models import PlaybackOperation
from .music_target_authority_models import (
    MusicTarget, MusicTargetProviderRevision,
)


class MusicTargetEffectEnvelope(StrictModel):
    executionId: ObjectId
    commandId: ObjectId
    requestId: ObjectId
    previewId: ObjectId
    installationId: ObjectId
    installationRevision: Revision
    coreRevision: Revision
    playerRevision: Revision
    providerRevisions: list[MusicTargetProviderRevision] = Field(
        min_length=1, max_length=256)
    target: MusicTarget
    operation: PlaybackOperation
    volumeLevel: int | None = Field(default=None, ge=0, le=100)
    muted: bool | None = None
    mediaUris: list[str] = Field(default_factory=list, max_length=64, repr=False)

    @model_validator(mode='after')
    def coherent(self):
        media = self.operation in {'queue_add', 'queue_replace'}
        capability = {
            'play': 'play', 'pause': 'pause', 'stop': 'stop',
            'next': 'next_previous', 'previous': 'next_previous',
            'volume': 'volume_set', 'mute': 'volume_mute',
            'queue_add': 'queue', 'queue_replace': 'queue',
            'queue_clear': 'queue',
        }[self.operation]
        if (media != bool(self.mediaUris)
                or (self.operation == 'volume') != (self.volumeLevel is not None)
                or (self.operation == 'mute') != (self.muted is not None)
                or len({item.id for item in self.providerRevisions})
                != len(self.providerRevisions)
                or not self.target.available or not self.target.enabled
                or capability not in self.target.capabilities
                or self.operation.startswith('queue_')
                and self.target.queueId is None):
            raise ValueError('invalid_music_target_effect')
        return self


class MusicTargetEffectResult(StrictModel):
    state: Literal['succeeded']
    executionId: ObjectId
    commandId: ObjectId
    requestId: ObjectId
    target: MusicTarget
