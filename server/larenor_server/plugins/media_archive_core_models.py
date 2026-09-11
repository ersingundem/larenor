"""Core API and private-worker contracts for one F30 archive read."""

from typing import Literal

from pydantic import Field, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from .media_archive_health_models import (
    ArchiveSourceBinding,
    MediaArchiveHealth,
)


class MediaArchiveReadRequest(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    expectedSnapshotRevision: Revision


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


class MediaArchiveReadResponse(StrictModel):
    requestId: ObjectId
    archive: MediaArchiveHealth
