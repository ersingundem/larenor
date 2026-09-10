"""Secret-free contracts for retained Music Assistant playback targets."""

import re
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from .music_playback_models import (
    MusicQueueSnapshot, PlaybackOperation, PlayerCapability,
)
from .music_provider_setup_models import ProviderDomain


class MusicTargetProviderRevision(StrictModel):
    id: ObjectId
    providerDomain: ProviderDomain
    revision: Revision


class MusicTarget(StrictModel):
    id: str = Field(min_length=1, max_length=128)
    name: str = Field(min_length=1, max_length=160)
    provider: str = Field(min_length=1, max_length=128)
    providerDomain: str = Field(min_length=1, max_length=64)
    providerInstanceId: str = Field(min_length=1, max_length=128)
    transport: Literal['airplay', 'chromecast']
    kind: Literal['device', 'group']
    homePod: bool
    available: bool
    enabled: bool
    playbackState: Literal['idle', 'playing', 'paused']
    volumeLevel: int | None = Field(default=None, ge=0, le=100)
    muted: bool | None = None
    groupMemberIds: list[str] = Field(max_length=64)
    queueId: str | None = Field(default=None, max_length=128)
    queue: MusicQueueSnapshot | None = None
    capabilities: list[PlayerCapability] = Field(max_length=8)

    @model_validator(mode='before')
    @classmethod
    def provider_metadata(cls, value):
        if type(value) is dict and type(value.get('provider')) is str:
            value = dict(value)
            value.setdefault('providerDomain', value['provider'].split('--', 1)[0])
            value.setdefault('providerInstanceId', value['provider'])
        return value

    @model_validator(mode='after')
    def coherent(self):
        if ((self.kind == 'group') != bool(self.groupMemberIds)
                or self.homePod and (self.transport != 'airplay'
                                     or self.kind != 'device')
                or len(set(self.groupMemberIds)) != len(self.groupMemberIds)
                or len(set(self.capabilities)) != len(self.capabilities)):
            raise ValueError('invalid_music_target')
        if (self.provider != self.providerInstanceId
                or self.providerDomain != self.provider.split('--', 1)[0]
                or (self.queue is not None and self.queue.id != self.queueId)):
            raise ValueError('invalid_music_target')
        return self


class ReadMusicTargetInventoryRequest(StrictModel):
    installationId: ObjectId
    expectedInstallationRevision: Revision
    expectedCoreRevision: Revision
    expectedPlayerRevision: Revision
    expectedProviderRevisions: list[MusicTargetProviderRevision] = Field(
        min_length=1, max_length=256)

    @model_validator(mode='after')
    def unique_provider_revisions(self):
        if len({item.id for item in self.expectedProviderRevisions}) != len(
                self.expectedProviderRevisions):
            raise ValueError('invalid_music_provider_revisions')
        return self


class MusicTargetInventory(StrictModel):
    installationId: ObjectId
    installationRevision: Revision
    coreRevision: Revision
    playerRevision: Revision
    providerRevisions: list[MusicTargetProviderRevision] = Field(max_length=256)
    targets: list[MusicTarget] = Field(max_length=256)
    installAvailable: Literal[False] = False
    updatedAt: str


class MusicTargetInventoryResponse(StrictModel):
    inventory: MusicTargetInventory


class CreateMusicTargetCommandPreviewRequest(ReadMusicTargetInventoryRequest):
    requestId: ObjectId
    targetId: str = Field(min_length=1, max_length=128)
    expectedProvider: str = Field(min_length=1, max_length=128)
    expectedTransport: Literal['airplay', 'chromecast']
    expectedKind: Literal['device', 'group']
    expectedQueueId: str | None = Field(default=None, max_length=128)
    expectedGroupMemberIds: list[str] = Field(max_length=64)
    operation: PlaybackOperation
    volumeLevel: int | None = Field(default=None, ge=0, le=100)
    muted: bool | None = None
    seekPosition: int | None = Field(default=None, ge=0, le=7 * 24 * 60 * 60)
    mediaUris: list[str] = Field(default_factory=list, max_length=64, repr=False)

    @model_validator(mode='after')
    def coherent_command(self):
        media = self.operation in {'queue_add', 'queue_replace'}
        if (media != bool(self.mediaUris)
                or (self.operation == 'volume') != (self.volumeLevel is not None)
                or (self.operation == 'mute') != (self.muted is not None)
                or (self.operation == 'seek') != (self.seekPosition is not None)
                or len(set(self.expectedGroupMemberIds)) != len(
                    self.expectedGroupMemberIds)
                or any(type(uri) is not str or not 0 < len(uri) <= 2048
                       or re.fullmatch(
                           r'(?:spotify|apple_music|ytmusic|library)://[^\s]+',
                           uri) is None for uri in self.mediaUris)):
            raise ValueError('invalid_music_target_command')
        return self


class MusicTargetCommandPreview(StrictModel):
    id: ObjectId
    revision: Literal[1]
    installationId: ObjectId
    installationRevision: Revision
    coreRevision: Revision
    playerRevision: Revision
    providerRevisions: list[MusicTargetProviderRevision] = Field(max_length=256)
    target: MusicTarget
    operation: PlaybackOperation
    volumeLevel: int | None
    muted: bool | None
    seekPosition: int | None
    mediaUris: list[str] = Field(max_length=64, repr=False)
    planHash: str = Field(pattern=r'^[0-9a-f]{64}$')
    effectAvailable: Literal[False]
    installAvailable: Literal[False]
    blockers: Literal[['effect_unavailable']]
    createdAt: str
    expiresAt: str


class MusicTargetCommandPreviewResponse(StrictModel):
    preview: MusicTargetCommandPreview


class ConfirmMusicTargetCommandRequest(StrictModel):
    requestId: ObjectId
    previewId: ObjectId
    expectedPreviewRevision: Literal[1]
    planHash: str = Field(pattern=r'^[0-9a-f]{64}$')


class MusicTargetCommand(StrictModel):
    id: ObjectId
    revision: Revision
    requestId: ObjectId
    previewId: ObjectId
    targetId: str = Field(min_length=1, max_length=128)
    target: MusicTarget
    operation: PlaybackOperation
    state: Literal['blocked', 'cancelled', 'unknown', 'succeeded']
    errorCode: Literal['effect_unavailable', 'effect_unknown'] | None
    result: 'MusicTargetEffectStatus | None'
    effectAvailable: bool
    installAvailable: Literal[False]
    createdAt: str

    @model_validator(mode='after')
    def coherent_result(self):
        expected = {
            'blocked': (1, 'effect_unavailable', None, False),
            'cancelled': (2, 'effect_unavailable', None, False),
            'unknown': (2, 'effect_unknown', 'unknown', True),
            'succeeded': (2, None, 'succeeded', True),
        }[self.state]
        if (self.revision != expected[0] or self.errorCode != expected[1]
                or (None if self.result is None else self.result.state)
                != expected[2] or self.effectAvailable != expected[3]):
            raise ValueError('invalid_music_target_command')
        return self


class MusicTargetCommandResponse(StrictModel):
    command: MusicTargetCommand


class MusicTargetEffectStatus(StrictModel):
    state: Literal['unknown', 'succeeded']
    code: Literal['effect_unknown', 'authenticated_readback']

    @model_validator(mode='after')
    def coherent(self):
        if self.code != ('authenticated_readback'
                         if self.state == 'succeeded' else 'effect_unknown'):
            raise ValueError('invalid_music_target_effect_status')
        return self


class CancelMusicTargetCommandRequest(StrictModel):
    requestId: ObjectId
    expectedRevision: Literal[1]


class MusicTargetHistoryRequest(ReadMusicTargetInventoryRequest):
    limit: int = Field(default=50, ge=1, le=100)
    before: ObjectId | None = None


class MusicTargetHistoryResponse(StrictModel):
    commands: list[MusicTargetCommand] = Field(max_length=100)
    nextBefore: ObjectId | None


class MusicTargetIntegrity(StrictModel):
    verified: Literal[True] = True
    commandCount: int = Field(ge=0, le=256)
    headHash: str = Field(pattern=r'^[0-9a-f]{64}$')
    installAvailable: Literal[False] = False


class MusicTargetIntegrityResponse(StrictModel):
    integrity: MusicTargetIntegrity
