"""Strict, secret-free contracts for the media archive health projection."""

import re
import unicodedata
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel


ArchiveService = Literal['jellyfin', 'sonarr', 'radarr', 'qbittorrent']
ArchiveSourceState = Literal['verified', 'unavailable', 'unsupported']
MediaKind = Literal['movie', 'episode']
_MEDIA_KEY = re.compile(
    r'(?:movie:tmdb:[1-9][0-9]{0,11}|episode:tvdb:[1-9][0-9]{0,11}:'
    r'[0-9]{1,4}:[0-9]{1,5})\Z'
)


def _safe_text(value: str) -> str:
    if value != value.strip() or any(
            unicodedata.category(character)[0] == 'C' for character in value):
        raise ValueError('invalid_media_archive_observation')
    return value


class ArchiveSourceBinding(StrictModel):
    serviceId: ArchiveService
    serviceRecordId: ObjectId
    serviceRevision: Revision
    snapshotRevision: Revision
    installationId: ObjectId
    installationRevision: Revision
    state: ArchiveSourceState
    observedAt: int = Field(ge=1, le=253402300799)


class JellyfinArchiveItem(StrictModel):
    itemId: ObjectId
    mediaKey: str = Field(min_length=1, max_length=96)
    title: str = Field(min_length=1, max_length=240)
    mediaKind: MediaKind
    sizeBytes: int = Field(ge=0, le=2**63 - 1)
    integrity: Literal['playable', 'missing_file', 'corrupt', 'unplayable']

    _key = field_validator('mediaKey')(
        lambda value: value if _MEDIA_KEY.fullmatch(value) else
        (_ for _ in ()).throw(ValueError('invalid_media_archive_observation')))
    _title = field_validator('title')(_safe_text)


class JellyfinArchiveSnapshot(ArchiveSourceBinding):
    serviceId: Literal['jellyfin']
    items: list[JellyfinArchiveItem] = Field(max_length=4096)

    @model_validator(mode='after')
    def coherent(self):
        if (self.state != 'verified' and self.items
                or len({item.itemId for item in self.items}) != len(self.items)):
            raise ValueError('invalid_media_archive_observation')
        return self


class ArrArchiveItem(StrictModel):
    mediaKey: str = Field(min_length=1, max_length=96)
    title: str = Field(min_length=1, max_length=240)
    mediaKind: MediaKind
    monitored: bool
    state: Literal['available', 'missing', 'queued', 'downloading', 'failed']

    _key = field_validator('mediaKey')(
        lambda value: value if _MEDIA_KEY.fullmatch(value) else
        (_ for _ in ()).throw(ValueError('invalid_media_archive_observation')))
    _title = field_validator('title')(_safe_text)


class ArrArchiveSnapshot(ArchiveSourceBinding):
    serviceId: Literal['sonarr', 'radarr']
    items: list[ArrArchiveItem] = Field(max_length=4096)

    @model_validator(mode='after')
    def coherent(self):
        if (self.state != 'verified' and self.items
                or len({item.mediaKey for item in self.items}) != len(self.items)
                or any(self.serviceId == 'sonarr' and item.mediaKind != 'episode'
                       for item in self.items)
                or any(self.serviceId == 'radarr' and item.mediaKind != 'movie'
                       for item in self.items)):
            raise ValueError('invalid_media_archive_observation')
        return self


class QbittorrentArchiveItem(StrictModel):
    torrentId: str = Field(min_length=40, max_length=64)
    mediaKey: str | None = Field(default=None, max_length=96)
    title: str = Field(min_length=1, max_length=240)
    contentBytes: int = Field(ge=0, le=2**63 - 1)
    state: Literal['downloading', 'seeding', 'complete', 'paused', 'error']
    importedConfirmed: bool
    retentionPolicySatisfied: bool

    @field_validator('torrentId')
    @classmethod
    def torrent_id(cls, value):
        if re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', value) is None:
            raise ValueError('invalid_media_archive_observation')
        return value

    @field_validator('mediaKey')
    @classmethod
    def media_key(cls, value):
        if value is not None and _MEDIA_KEY.fullmatch(value) is None:
            raise ValueError('invalid_media_archive_observation')
        return value

    _title = field_validator('title')(_safe_text)

    @model_validator(mode='after')
    def coherent(self):
        if (self.importedConfirmed and self.mediaKey is None
                or self.retentionPolicySatisfied and (
                    not self.importedConfirmed or self.state != 'complete')):
            raise ValueError('invalid_media_archive_observation')
        return self


class QbittorrentArchiveSnapshot(ArchiveSourceBinding):
    serviceId: Literal['qbittorrent']
    items: list[QbittorrentArchiveItem] = Field(max_length=4096)

    @model_validator(mode='after')
    def coherent(self):
        if (self.state != 'verified' and self.items
                or len({item.torrentId for item in self.items}) != len(self.items)):
            raise ValueError('invalid_media_archive_observation')
        return self


class MediaArchiveObservation(StrictModel):
    jellyfin: JellyfinArchiveSnapshot
    sonarr: ArrArchiveSnapshot
    radarr: ArrArchiveSnapshot
    qbittorrent: QbittorrentArchiveSnapshot

    @model_validator(mode='after')
    def exact_sources(self):
        if self.sonarr.serviceId != 'sonarr' or self.radarr.serviceId != 'radarr':
            raise ValueError('invalid_media_archive_observation')
        return self


class MediaArchiveIssue(StrictModel):
    code: Literal['missing_media', 'missing_file', 'corrupt_media',
                  'unplayable_media', 'download_error']
    severity: Literal['warning', 'critical']
    source: ArchiveService
    sourceItemId: str = Field(min_length=1, max_length=96)
    mediaKey: str | None
    title: str
    observedBytes: int = Field(ge=0, le=2**63 - 1)


class MediaArchiveSavingSuggestion(StrictModel):
    code: Literal['review_retained_download']
    torrentId: str
    mediaKey: str
    title: str
    potentialBytes: int = Field(gt=0, le=2**63 - 1)
    evidence: list[Literal['download_complete', 'import_verified',
                           'retention_policy_satisfied']] = Field(
                               min_length=3, max_length=3)
    cleanupAvailable: Literal[False] = False


class MediaArchiveCounts(StrictModel):
    missing: int = Field(ge=0, le=8192)
    broken: int = Field(ge=0, le=8192)
    failedDownloads: int = Field(ge=0, le=4096)
    savingCandidates: int = Field(ge=0, le=4096)
    potentialSavingBytes: int = Field(ge=0, le=2**63 - 1)


class MediaArchiveHealth(StrictModel):
    installationId: ObjectId
    installationRevision: Revision
    snapshotRevision: Revision
    state: Literal['healthy', 'attention', 'incomplete']
    sourceStates: dict[ArchiveService, Literal[
        'verified', 'unavailable', 'unsupported', 'stale']]
    sourceRevisions: dict[ArchiveService, Revision]
    counts: MediaArchiveCounts
    issues: list[MediaArchiveIssue] = Field(max_length=12288)
    suggestions: list[MediaArchiveSavingSuggestion] = Field(max_length=4096)
    cleanupAvailable: Literal[False] = False
    generatedAt: int = Field(ge=1, le=253402300799)

    @model_validator(mode='after')
    def exact_sources(self):
        expected = {'jellyfin', 'sonarr', 'radarr', 'qbittorrent'}
        if set(self.sourceStates) != expected or set(self.sourceRevisions) != expected:
            raise ValueError('invalid_media_archive_health')
        return self
