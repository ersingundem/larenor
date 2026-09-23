"""Strict public and private contracts for verified Music Assistant playback."""

import re
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel


PlaybackOperation = Literal[
    'play', 'pause', 'seek', 'stop', 'next', 'previous', 'volume', 'mute',
    'queue_add', 'queue_replace', 'queue_clear',
]
PlayerCapability = Literal[
    'play', 'pause', 'seek', 'stop', 'next_previous', 'volume_set', 'volume_mute',
    'queue',
]


class VerifiedMusicPlayer(StrictModel):
    playerId: str = Field(min_length=1, max_length=128)
    name: str = Field(min_length=1, max_length=160)
    provider: str = Field(min_length=1, max_length=128)
    targetKind: Literal[
        'homepod', 'airplay', 'airplay_group', 'cast', 'cast_group', 'group',
        'other',
    ]
    available: bool
    enabled: bool
    playbackState: Literal['idle', 'playing', 'paused']
    volumeLevel: int | None = Field(default=None, ge=0, le=100)
    muted: bool | None = None
    groupMembers: list[str] = Field(max_length=64)
    queueId: str | None = Field(default=None, max_length=128)
    positionSeconds: float | None = Field(default=None, ge=0, le=864000)
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
        if self.targetKind in {'airplay_group', 'group'} and not self.groupMembers:
            raise ValueError('invalid_music_player_readback')
        if self.targetKind not in {'airplay_group', 'group'} and self.groupMembers:
            raise ValueError('invalid_music_player_readback')
        return self


class VerifiedMusicQueue(StrictModel):
    queueId: str = Field(min_length=1, max_length=128)
    active: bool
    itemCount: int = Field(ge=0, le=100000)
    currentItemUri: str | None = Field(default=None, max_length=2048)
    positionSeconds: float = Field(ge=0, le=864000)

    @field_validator('queueId')
    @classmethod
    def safe_queue_id(cls, value):
        if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}', value) is None:
            raise ValueError('invalid_music_queue_readback')
        return value

    @field_validator('currentItemUri')
    @classmethod
    def safe_uri(cls, value):
        if (value is not None and re.fullmatch(
                r'(?:spotify|apple_music|ytmusic|library)://[^\s]+', value)
                is None):
            raise ValueError('invalid_music_queue_readback')
        return value


class MusicManagerProvider(StrictModel):
    setupId: ObjectId
    revision: Revision
    providerDomain: Literal['spotify', 'apple_music', 'ytmusic']
    providerInstanceId: str = Field(min_length=1, max_length=128)
    catalogAvailable: Literal[True] = True

    @field_validator('providerInstanceId')
    @classmethod
    def safe_instance_id(cls, value):
        if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}', value) is None:
            raise ValueError('invalid_music_provider_binding')
        return value


class MusicCatalogItem(StrictModel):
    uri: str = Field(min_length=1, max_length=2048)
    name: str = Field(min_length=1, max_length=512)
    mediaType: Literal[
        'artist', 'album', 'track', 'playlist', 'radio', 'audiobook',
        'podcast',
    ]
    providerInstanceId: str = Field(min_length=1, max_length=128)
    artists: list[str] = Field(default_factory=list, max_length=32)

    @model_validator(mode='after')
    def safe_public_fields(self):
        if (re.fullmatch(r'(?:spotify|apple_music|ytmusic|library)://[^\s]+',
                         self.uri) is None
                or re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}',
                                self.providerInstanceId) is None
                or any(not isinstance(value, str) or not 0 < len(value) <= 256
                       or any(ord(char) < 32 or ord(char) == 127
                              for char in value)
                       for value in [self.name, *self.artists])):
            raise ValueError('invalid_music_catalog_readback')
        return self


class MusicPlaybackReadback(StrictModel):
    players: list[VerifiedMusicPlayer] = Field(max_length=256)
    queues: list[VerifiedMusicQueue] = Field(default_factory=list,
                                             max_length=256)

    @model_validator(mode='after')
    def unique_players(self):
        if len({item.playerId for item in self.players}) != len(self.players):
            raise ValueError('invalid_music_player_readback')
        known = {item.playerId for item in self.players}
        if any(not set(item.groupMembers) <= known for item in self.players):
            raise ValueError('invalid_music_player_readback')
        if len({item.queueId for item in self.queues}) != len(self.queues):
            raise ValueError('invalid_music_queue_readback')
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
        'homepod', 'airplay', 'airplay_group', 'cast', 'cast_group', 'group',
        'other']
    expectedQueueId: str | None = Field(default=None, max_length=128)
    expectedGroupMembers: list[str] = Field(max_length=64)
    operation: PlaybackOperation
    volumeLevel: int | None = Field(default=None, ge=0, le=100)
    muted: bool | None = None
    positionSeconds: float | None = Field(default=None, ge=0, le=864000)
    mediaUris: list[str] = Field(default_factory=list, max_length=64, repr=False)

    @model_validator(mode='after')
    def coherent(self):
        media = self.operation in {'queue_add', 'queue_replace'}
        if (media != bool(self.mediaUris)
                or (self.operation == 'volume') != (self.volumeLevel is not None)
                or (self.operation == 'mute') != (self.muted is not None)
                or (self.operation == 'seek') != (self.positionSeconds is not None)
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


class MusicManagerState(StrictModel):
    installationId: ObjectId
    installationRevision: Revision
    coreRevision: Revision
    revision: Revision
    providers: list[MusicManagerProvider] = Field(max_length=256)
    queues: list[VerifiedMusicQueue] = Field(max_length=256)
    receivers: list[VerifiedMusicPlayer] = Field(max_length=256)
    installAvailable: Literal[False] = False
    updatedAt: str


class MusicManagerStateResponse(StrictModel):
    manager: MusicManagerState


class SearchMusicCatalogRequest(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    expectedCoreRevision: Revision
    expectedManagerRevision: Revision
    providerSetupId: ObjectId
    expectedProviderRevision: Revision
    providerDomain: Literal['spotify', 'apple_music', 'ytmusic']
    providerInstanceId: str = Field(min_length=1, max_length=128)
    query: str = Field(min_length=1, max_length=160)
    mediaTypes: list[Literal[
        'artist', 'album', 'track', 'playlist', 'radio', 'audiobook',
        'podcast',
    ]] = Field(default_factory=list, max_length=7)
    limit: int = Field(default=25, ge=1, le=100)
    libraryOnly: bool = False

    @model_validator(mode='after')
    def coherent(self):
        if (self.query != self.query.strip()
                or any(ord(char) < 32 or ord(char) == 127
                       for char in self.query)
                or len(set(self.mediaTypes)) != len(self.mediaTypes)
                or re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}',
                                self.providerInstanceId) is None):
            raise ValueError('invalid_music_catalog_search')
        return self


class MusicCatalogSearchResult(StrictModel):
    requestId: ObjectId
    managerRevision: Revision
    items: list[MusicCatalogItem] = Field(max_length=100)


class MusicCatalogSearchResponse(StrictModel):
    catalog: MusicCatalogSearchResult


class ReadMusicLongformRequest(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    expectedCoreRevision: Revision
    expectedManagerRevision: Revision
    limit: int = Field(default=10, ge=1, le=25)


class MusicLongformChapter(StrictModel):
    position: int = Field(ge=0, le=10000)
    name: str = Field(min_length=1, max_length=256)
    startSeconds: float = Field(ge=0, le=8640000)
    endSeconds: float | None = Field(default=None, ge=0, le=8640000)

    @model_validator(mode='after')
    def coherent(self):
        if (self.name != self.name.strip()
                or any(ord(char) < 32 or ord(char) == 127 for char in self.name)
                or self.endSeconds is not None
                and self.endSeconds <= self.startSeconds):
            raise ValueError('invalid_music_longform_readback')
        return self


class MusicLongformItem(StrictModel):
    uri: str = Field(min_length=1, max_length=2048)
    name: str = Field(min_length=1, max_length=512)
    mediaType: Literal['audiobook', 'podcast_episode']
    providerInstanceId: str = Field(min_length=1, max_length=128)
    durationSeconds: float = Field(gt=0, le=8640000)
    resumePositionSeconds: float = Field(ge=0, le=8640000)
    fullyPlayed: Literal[False] = False
    chapters: list[MusicLongformChapter] = Field(default_factory=list,
                                                  max_length=512)

    @model_validator(mode='after')
    def coherent(self):
        uri = re.fullmatch(r'([a-z][a-z0-9_]{0,63})://[^\s]+', self.uri)
        if (uri is None
                or uri.group(1) in {
                    'content', 'data', 'file', 'ftp', 'http', 'https',
                    'javascript'}
                or any(ord(char) < 33 or ord(char) == 127
                       for char in self.uri)
                or re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}',
                                self.providerInstanceId) is None
                or self.name != self.name.strip()
                or any(ord(char) < 32 or ord(char) == 127 for char in self.name)
                or self.resumePositionSeconds > self.durationSeconds):
            raise ValueError('invalid_music_longform_readback')
        previous_position = -1
        previous_start = -1.0
        previous_end = None
        for chapter in self.chapters:
            if (chapter.position <= previous_position
                    or chapter.startSeconds <= previous_start
                    or previous_end is not None
                    and chapter.startSeconds < previous_end
                    or chapter.startSeconds >= self.durationSeconds
                    or chapter.endSeconds is not None
                    and chapter.endSeconds > self.durationSeconds):
                raise ValueError('invalid_music_longform_readback')
            previous_position = chapter.position
            previous_start = chapter.startSeconds
            previous_end = chapter.endSeconds
        return self


class MusicLongformCatalog(StrictModel):
    requestId: ObjectId
    managerRevision: Revision
    items: list[MusicLongformItem] = Field(max_length=25)


class MusicLongformCatalogResponse(StrictModel):
    longform: MusicLongformCatalog


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


class PrivateMusicPlaybackAction(StrictModel):
    request: MusicPlaybackCommandRequest = Field(repr=False)
    token: str = Field(min_length=1, max_length=2048, repr=False)


class PrivateMusicCatalogAction(StrictModel):
    request: SearchMusicCatalogRequest = Field(repr=False)
    token: str = Field(min_length=1, max_length=2048, repr=False)


class PrivateMusicLongformAction(StrictModel):
    request: ReadMusicLongformRequest = Field(repr=False)
    allowedProviderInstanceIds: list[str] = Field(min_length=1, max_length=256,
                                                   repr=False)
    token: str = Field(min_length=1, max_length=2048, repr=False)

    @model_validator(mode='after')
    def coherent(self):
        if (len(set(self.allowedProviderInstanceIds))
                != len(self.allowedProviderInstanceIds)
                or any(re.fullmatch(
                    r'[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}', value) is None
                    for value in self.allowedProviderInstanceIds)):
            raise ValueError('invalid_music_longform_authority')
        return self


class MusicCatalogWorkerResult(StrictModel):
    items: list[MusicCatalogItem] = Field(max_length=100)


class MusicLongformWorkerResult(StrictModel):
    items: list[MusicLongformItem] = Field(max_length=25)


class MusicPlaybackWorkerResult(StrictModel):
    state: Literal['succeeded']
    target: VerifiedMusicPlayer
    queue: VerifiedMusicQueue | None = None


class _StoredPlaybackCommand(StrictModel):
    actorId: ObjectId
    request: MusicPlaybackCommandRequest = Field(repr=False)
    state: Literal['pending', 'succeeded']
    playerRevision: Revision


class _StoredMusicPlayback(StrictModel):
    players: list[VerifiedMusicPlayer] = Field(max_length=256)
    queues: list[VerifiedMusicQueue] = Field(default_factory=list,
                                             max_length=256)
    providerBindings: list[MusicManagerProvider] = Field(default_factory=list,
                                                          max_length=256)
    commands: list[_StoredPlaybackCommand] = Field(default_factory=list,
                                                   max_length=256, repr=False)
