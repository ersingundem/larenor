"""Strict public contracts for travel-safe offline media."""

from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from ..plugins.media_playback_models import PrepareMediaPlaybackIntentRequest


def _exact_version(value):
    if type(value) is not int:
        raise ValueError("invalid_schema")
    return value


class Versioned(StrictModel):
    schemaVersion: Literal[1] = 1
    _version = field_validator("schemaVersion", mode="before")(_exact_version)


class CreateOfflineMediaRequest(PrepareMediaPlaybackIntentRequest):
    schemaVersion: Literal[1] = 1
    expiresAt: int = Field(ge=1, le=253402300799)
    storageQuotaBytes: int = Field(ge=64 * 1024 * 1024, le=2**63 - 1)
    storageAvailableBytes: int = Field(ge=0, le=2**63 - 1)
    _version = field_validator("schemaVersion", mode="before")(_exact_version)


class OfflineMediaAuthority(Versioned):
    coreId: ObjectId
    homeId: ObjectId
    accountId: ObjectId
    accountRevision: Revision
    sessionFamilyId: ObjectId
    installationId: ObjectId
    installationRevision: Revision
    snapshotRevision: Revision
    jellyfinServiceRevision: Revision
    itemId: ObjectId
    mediaKey: str = Field(min_length=1, max_length=96)


class OfflineMediaManifest(Versioned):
    grantId: ObjectId
    revision: Revision
    authority: OfflineMediaAuthority
    title: str = Field(min_length=1, max_length=240)
    contentLength: int = Field(ge=1, le=2**63 - 1)
    contentSha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    contentType: str = Field(min_length=1, max_length=128)
    chunkBytes: int = Field(ge=16 * 1024, le=1024 * 1024)
    downloadedBytes: int = Field(ge=0, le=2**63 - 1)
    state: Literal["granted", "transferring", "complete", "revoked"]
    expiresAt: int = Field(ge=1, le=253402300799)

    @model_validator(mode="after")
    def coherent(self):
        if (self.downloadedBytes > self.contentLength
                or self.state == "complete"
                and self.downloadedBytes != self.contentLength
                or self.state in {"granted", "transferring"}
                and self.downloadedBytes == self.contentLength):
            raise ValueError("invalid_offline_media_manifest")
        return self


class OfflineMediaManifestResponse(StrictModel):
    manifest: OfflineMediaManifest


class UpdateOfflineMediaProgressRequest(Versioned):
    requestId: ObjectId
    expectedRevision: Revision
    downloadedBytes: int = Field(ge=0, le=2**63 - 1)
    contentSha256: str | None = Field(default=None, pattern=r"^[0-9a-f]{64}$")


class RevokeOfflineMediaRequest(Versioned):
    requestId: ObjectId
    expectedRevision: Revision
