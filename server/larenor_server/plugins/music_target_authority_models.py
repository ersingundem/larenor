"""Secret-free contracts for retained Music Assistant playback targets."""

import re
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from .music_playback_models import PlaybackOperation, PlayerCapability
from .music_provider_setup_models import ProviderDomain


class MusicTargetProviderRevision(StrictModel):
    id: ObjectId
    providerDomain: ProviderDomain
    revision: Revision


class MusicTarget(StrictModel):
    id: str = Field(min_length=1, max_length=128)
    name: str = Field(min_length=1, max_length=160)
    provider: str = Field(min_length=1, max_length=128)
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
    capabilities: list[PlayerCapability] = Field(max_length=7)

    @model_validator(mode='after')
    def coherent(self):
        if ((self.kind == 'group') != bool(self.groupMemberIds)
                or self.homePod and (self.transport != 'airplay'
                                     or self.kind != 'device')
                or len(set(self.groupMemberIds)) != len(self.groupMemberIds)
                or len(set(self.capabilities)) != len(self.capabilities)):
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
    mediaUris: list[str] = Field(default_factory=list, max_length=64, repr=False)

    @model_validator(mode='after')
    def coherent_command(self):
        media = self.operation in {'queue_add', 'queue_replace'}
        if (media != bool(self.mediaUris)
                or (self.operation == 'volume') != (self.volumeLevel is not None)
                or (self.operation == 'mute') != (self.muted is not None)
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
    revision: Literal[1]
    requestId: ObjectId
    previewId: ObjectId
    targetId: str = Field(min_length=1, max_length=128)
    target: MusicTarget
    operation: PlaybackOperation
    state: Literal['blocked']
    errorCode: Literal['effect_unavailable']
    result: None
    effectAvailable: Literal[False]
    installAvailable: Literal[False]
    createdAt: str


class MusicTargetCommandResponse(StrictModel):
    command: MusicTargetCommand
