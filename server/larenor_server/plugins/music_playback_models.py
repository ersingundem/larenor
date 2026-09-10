"""Strict public and private contracts for verified Music Assistant playback."""

import re
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel


PlaybackOperation = Literal[
    'play', 'pause', 'resume', 'stop', 'seek', 'next', 'previous', 'volume', 'mute',
    'queue_add', 'queue_replace', 'queue_clear',
]
PlayerCapability = Literal[
    'play', 'pause', 'stop', 'seek', 'next_previous', 'volume_set', 'volume_mute',
    'queue',
]


class VerifiedMusicPlayer(StrictModel):
    playerId: str = Field(min_length=1, max_length=128)
    name: str = Field(min_length=1, max_length=160)
    provider: str = Field(min_length=1, max_length=128)
    targetKind: Literal[
        'homepod', 'airplay', 'airplay_group', 'chromecast',
        'chromecast_group', 'group', 'other']
    available: bool
    enabled: bool
    playbackState: Literal['idle', 'playing', 'paused']
    volumeLevel: int | None = Field(default=None, ge=0, le=100)
    muted: bool | None = None
    groupMembers: list[str] = Field(max_length=64)
    queueId: str | None = Field(default=None, max_length=128)
    capabilities: list[PlayerCapability] = Field(max_length=8)

    @field_validator('playerId', 'provider', 'queueId')
    @classmethod
    def safe_id(cls, value):
        if (value is not None
                and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}',
                                 value) is None):
            raise ValueError('invalid_music_player_readback')
        return value

    @field_validator('name')
    @classmethod
    def safe_name(cls, value):
        if any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError('invalid_music_player_readback')
        return value

    @model_validator(mode='after')
    def coherent(self):
        if (len(set(self.groupMembers)) != len(self.groupMembers)
                or any(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}', item)
                       is None for item in self.groupMembers)
                or len(set(self.capabilities)) != len(self.capabilities)):
            raise ValueError('invalid_music_player_readback')
        if self.targetKind in {
                'airplay_group', 'chromecast_group', 'group'} and not self.groupMembers:
            raise ValueError('invalid_music_player_readback')
        if self.targetKind not in {
                'airplay_group', 'chromecast_group', 'group'} and self.groupMembers:
            raise ValueError('invalid_music_player_readback')
        return self


class MusicPlaybackReadback(StrictModel):
    players: list[VerifiedMusicPlayer] = Field(max_length=256)

    @model_validator(mode='after')
    def unique_players(self):
        if len({item.playerId for item in self.players}) != len(self.players):
            raise ValueError('invalid_music_player_readback')
        known = {item.playerId for item in self.players}
        if any(not set(item.groupMembers) <= known for item in self.players):
            raise ValueError('invalid_music_player_readback')
        return self


class RefreshMusicPlaybackRequest(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    expectedCoreRevision: Revision


class MusicPlaybackCommandRequest(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    expectedCoreRevision: Revision
    expectedPlayerRevision: Revision
    targetId: str = Field(min_length=1, max_length=128)
    expectedProvider: str = Field(min_length=1, max_length=128)
    expectedTargetKind: Literal[
        'homepod', 'airplay', 'airplay_group', 'chromecast',
        'chromecast_group', 'group', 'other']
    expectedQueueId: str | None = Field(default=None, max_length=128)
    expectedGroupMembers: list[str] = Field(max_length=64)
    operation: PlaybackOperation
    volumeLevel: int | None = Field(default=None, ge=0, le=100)
    muted: bool | None = None
    seekPosition: int | None = Field(default=None, ge=0, le=7 * 24 * 60 * 60)
    mediaUris: list[str] = Field(default_factory=list, max_length=64, repr=False)

    @model_validator(mode='after')
    def coherent(self):
        media = self.operation in {'queue_add', 'queue_replace'}
        if (media != bool(self.mediaUris)
                or (self.operation == 'volume') != (self.volumeLevel is not None)
                or (self.operation == 'mute') != (self.muted is not None)
                or (self.operation == 'seek') != (self.seekPosition is not None)
                or len(set(self.expectedGroupMembers)) != len(self.expectedGroupMembers)):
            raise ValueError('invalid_music_playback_command')
        if (any(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}', item)
                is None for item in self.expectedGroupMembers)
                or any(value is not None
                       and re.fullmatch(
                           r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}', value)
                       is None for value in (
                           self.expectedProvider, self.expectedQueueId))
                or any(type(uri) is not str or not 0 < len(uri) <= 2048
               or re.fullmatch(r'(?:spotify|apple_music|ytmusic|library)://[^\s]+',
                               uri) is None
               for uri in self.mediaUris)):
            raise ValueError('invalid_music_playback_command')
        return self


class MusicPlaybackState(StrictModel):
    installationId: ObjectId
    installationRevision: Revision
    coreRevision: Revision
    revision: Revision
    players: list[VerifiedMusicPlayer] = Field(max_length=256)
    installAvailable: Literal[False] = False
    updatedAt: str


class MusicPlaybackStateResponse(StrictModel):
    playback: MusicPlaybackState


class MusicPlaybackReceipt(StrictModel):
    requestId: ObjectId
    targetId: str = Field(min_length=1, max_length=128)
    operation: PlaybackOperation
    state: Literal['succeeded', 'needs_attention']
    playerRevision: Revision
    code: Literal['authenticated_readback', 'effect_unknown']
    installAvailable: Literal[False] = False


class MusicPlaybackReceiptResponse(StrictModel):
    receipt: MusicPlaybackReceipt


class PrivateMusicPlaybackAuthority(StrictModel):
    installationId: ObjectId
    token: str = Field(min_length=1, max_length=2048, repr=False)


class PrivateMusicAssistantServiceBinding(StrictModel):
    installationId: ObjectId
    installationRevision: Revision
    coreRevision: Revision
    serviceId: ObjectId
    serviceRevision: Revision
    egressPolicyRevision: int = Field(ge=1, le=2**63 - 1)
    endpoint: str = Field(min_length=1, max_length=256, repr=False)
    pinnedPeer: str = Field(min_length=7, max_length=45)
    serverId: str = Field(min_length=1, max_length=128)
    serverVersion: str = Field(min_length=1, max_length=80)
    schemaVersion: int = Field(ge=1, le=2**31 - 1)
    token: str = Field(min_length=1, max_length=2048, repr=False)

    @model_validator(mode='after')
    def private_numeric_endpoint(self):
        import ipaddress
        from urllib.parse import urlsplit
        try:
            parsed = urlsplit(self.endpoint)
            address = ipaddress.ip_address(parsed.hostname or '')
            if (parsed.scheme != 'http' or parsed.username is not None
                    or parsed.password is not None or parsed.path not in {'', '/'}
                    or parsed.query or parsed.fragment or parsed.port is None
                    or str(address) != self.pinnedPeer
                    or not (address.is_private or address.is_loopback)):
                raise ValueError()
        except Exception:
            raise ValueError('invalid_music_service_binding') from None
        return self


class PrivateMusicPlaybackAction(StrictModel):
    request: MusicPlaybackCommandRequest = Field(repr=False)
    token: str = Field(min_length=1, max_length=2048, repr=False)


class MusicPlaybackWorkerResult(StrictModel):
    state: Literal['succeeded']
    target: VerifiedMusicPlayer


class _StoredPlaybackCommand(StrictModel):
    actorId: ObjectId
    request: MusicPlaybackCommandRequest = Field(repr=False)
    state: Literal['pending', 'succeeded']
    playerRevision: Revision


class _StoredMusicPlayback(StrictModel):
    players: list[VerifiedMusicPlayer] = Field(max_length=256)
    commands: list[_StoredPlaybackCommand] = Field(default_factory=list,
                                                   max_length=256, repr=False)
