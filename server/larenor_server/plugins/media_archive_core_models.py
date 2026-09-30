"""Core API and private-worker contracts for one F30 archive read."""

import re
import unicodedata
from typing import Literal

from pydantic import ConfigDict, Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from .media_archive_health_models import (
    ArchiveSourceBinding,
    MediaArchiveHealth,
    MediaKind,
)
from .stack_plan import MediaStackPlan


class MediaArchiveReadRequest(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    expectedSnapshotRevision: Revision


class MediaArchiveAuthorityRequest(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision


class MediaArchiveAuthorityResponse(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    installationRevision: Revision
    snapshotRevision: Revision


class MediaArchiveCollectionAuthority(StrictModel):
    installationId: ObjectId
    installationRevision: Revision
    snapshotRevision: Revision
    sources: list[ArchiveSourceBinding] = Field(
        min_length=4, max_length=4, repr=False)

    @model_validator(mode='after')
    def exact_sources(self):
        expected = {'jellyfin', 'sonarr', 'radarr', 'qbittorrent'}
        if ({item.serviceId for item in self.sources} != expected
                or any(item.installationId != self.installationId
                       or item.installationRevision != self.installationRevision
                       or item.snapshotRevision != self.snapshotRevision
                       or item.state != 'verified' for item in self.sources)):
            raise ValueError('invalid_media_archive_authority')
        return self


class PrivateMediaArchiveCollection(StrictModel):
    requestId: ObjectId
    authority: MediaArchiveCollectionAuthority = Field(repr=False)
    operation: Literal['read_archive_health'] = 'read_archive_health'


class PrivateMediaArchiveSourceCredential(StrictModel):
    """One revision-bound credential carried only over private worker IPC."""

    model_config = ConfigDict(extra='forbid', strict=True, frozen=True)

    serviceId: Literal['jellyfin', 'sonarr', 'radarr', 'qbittorrent']
    serviceRecordId: ObjectId
    serviceRevision: Revision
    apiKey: str = Field(min_length=32, max_length=128, repr=False)
    serverId: ObjectId | None = Field(default=None, repr=False)
    containerId: str | None = Field(
        default=None, pattern=r'^[0-9a-f]{64}$', repr=False)

    @model_validator(mode='after')
    def exact_private_shape(self):
        if ((self.serviceId == 'jellyfin') != (self.serverId is not None)
                or (self.serviceId == 'jellyfin') ==
                (self.containerId is not None)
                or self.serviceId == 'jellyfin'
                and re.fullmatch(r'[A-Za-z0-9_-]{32,128}', self.apiKey) is None
                or self.serviceId in {'sonarr', 'radarr'}
                and re.fullmatch(r'[0-9a-f]{32}', self.apiKey) is None
                or self.serviceId == 'qbittorrent'
                and re.fullmatch(
                    r'qbt_[A-Za-z0-9_-]{28}', self.apiKey) is None):
            raise ValueError('invalid_media_archive_private_source')
        return self

    def __repr__(self):
        return 'PrivateMediaArchiveSourceCredential(<private>)'


class PrivateMediaArchiveWorkerCollection(StrictModel):
    """Exact Core-owned authority and secrets for one read-only worker call."""

    model_config = ConfigDict(extra='forbid', strict=True, frozen=True)

    requestId: ObjectId
    authority: MediaArchiveCollectionAuthority = Field(repr=False)
    plan: MediaStackPlan = Field(repr=False)
    sources: list[PrivateMediaArchiveSourceCredential] = Field(
        min_length=4, max_length=4, repr=False)
    operation: Literal['read_archive_health'] = 'read_archive_health'

    @model_validator(mode='after')
    def exact_private_sources(self):
        order = ('jellyfin', 'sonarr', 'radarr', 'qbittorrent')
        if (tuple(item.serviceId for item in self.sources) != order
                or {item.serviceId: (item.serviceRecordId, item.serviceRevision)
                    for item in self.sources} != {
                        item.serviceId: (item.serviceRecordId,
                                         item.serviceRevision)
                        for item in self.authority.sources}):
            raise ValueError('invalid_media_archive_private_sources')
        return self

    def __repr__(self):
        return 'PrivateMediaArchiveWorkerCollection(<private>)'


class MediaArchiveReadResponse(StrictModel):
    requestId: ObjectId
    archive: MediaArchiveHealth


class MediaCatalogSearchRequest(MediaArchiveReadRequest):
    query: str = Field(min_length=1, max_length=80)
    mediaKind: Literal['movie', 'episode'] | None
    offset: int = Field(ge=0, le=4096)
    limit: int = Field(ge=1, le=50)

    @field_validator('query')
    @classmethod
    def safe_query(cls, value):
        if (value != value.strip()
                or unicodedata.normalize('NFKC', value) != value
                or any(unicodedata.category(char)[0] == 'C' for char in value)):
            raise ValueError('invalid_media_catalog_query')
        return value


class MediaCatalogBrowseRequest(MediaArchiveReadRequest):
    mediaKind: Literal['movie', 'episode'] | None
    offset: int = Field(ge=0, le=4096)
    limit: int = Field(ge=1, le=50)


class MediaCatalogResolveRequest(MediaArchiveReadRequest):
    """Resolve one opaque Jellyfin item through the current catalog proof."""

    itemId: ObjectId


class MediaCatalogItem(StrictModel):
    itemId: ObjectId
    mediaKey: str = Field(min_length=1, max_length=96)
    title: str = Field(min_length=1, max_length=240)
    mediaKind: MediaKind
    runtimeSeconds: int | None = Field(default=None, gt=0, le=604_800)


class MediaCatalogPage(StrictModel):
    schemaVersion: Literal[1]
    installationId: ObjectId
    installationRevision: Revision
    snapshotRevision: Revision
    jellyfinServiceRevision: Revision
    offset: int = Field(ge=0, le=4096)
    nextOffset: int | None = Field(default=None, ge=1, le=4096)
    total: int = Field(ge=0, le=4096)
    items: list[MediaCatalogItem] = Field(max_length=50)

    @model_validator(mode='after')
    def coherent_page(self):
        end = self.offset + len(self.items)
        if (self.offset > self.total
                or self.nextOffset is None and end != self.total
                or self.nextOffset is not None
                and (self.nextOffset != end or self.nextOffset >= self.total)
                or len({item.itemId for item in self.items}) != len(self.items)):
            raise ValueError('invalid_media_catalog_page')
        return self


class MediaCatalogSearchResponse(StrictModel):
    requestId: ObjectId
    catalog: MediaCatalogPage


class MediaCatalogTargetResponse(StrictModel):
    schemaVersion: Literal[1]
    installationId: ObjectId
    installationRevision: Revision
    snapshotRevision: Revision
    jellyfinServiceRevision: Revision
