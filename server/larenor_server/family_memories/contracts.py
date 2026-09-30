"""Strict versioned HTTP contracts for F38 family memories."""

from typing import Literal

from pydantic import Field, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel


class MemoryVersioned(StrictModel):
    schemaVersion: Literal[1] = 1


class MemoryAuthorityContract(StrictModel):
    coreId: ObjectId
    homeId: ObjectId
    accountId: ObjectId
    sessionId: ObjectId
    membersRevision: Revision


class MemoryBindingContract(StrictModel):
    serviceId: ObjectId
    serviceRevision: Revision
    allowedAlbumIds: list[str] = Field(min_length=1, max_length=32)
    faceSearchEnabled: bool


class MemorySelectionContract(StrictModel):
    assetId: str = Field(pattern=r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    sourceAlbumId: str = Field(pattern=r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    sourceEtag: str = Field(pattern=r"^[0-9a-f]{64}$")


class MemoryAssetContract(StrictModel):
    assetId: str
    fileName: str = Field(min_length=1, max_length=512)
    takenAt: str = Field(min_length=1, max_length=40)
    thumbhash: str | None = Field(default=None, max_length=1024)
    sourceEtag: str = Field(pattern=r"^[0-9a-f]{64}$")
    sourceAlbumId: str = Field(pattern=r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")


class MemoryAlbumContract(StrictModel):
    albumId: ObjectId
    revision: Revision
    title: str = Field(min_length=1, max_length=120)
    visibility: Literal["personal", "shared"]
    ownerId: ObjectId
    memberIds: list[ObjectId] = Field(min_length=1, max_length=32)
    serviceId: ObjectId
    serviceRevision: Revision
    assets: list[MemorySelectionContract] = Field(max_length=250)
    updatedAt: float = Field(ge=0)

    @model_validator(mode="after")
    def coherent(self):
        if (len(set(self.memberIds)) != len(self.memberIds)
                or self.ownerId not in self.memberIds
                or self.visibility == "personal"
                and self.memberIds != [self.ownerId]
                or len({item.assetId for item in self.assets})
                != len(self.assets)):
            raise ValueError("invalid_memory_album")
        return self


class MemorySnapshot(MemoryVersioned):
    authority: MemoryAuthorityContract
    binding: MemoryBindingContract
    memberIds: list[ObjectId] = Field(min_length=1, max_length=32)
    albums: list[MemoryAlbumContract] = Field(max_length=64)


class MemorySnapshotRequest(MemoryVersioned):
    requestId: ObjectId


class MemorySourceRequest(MemorySnapshotRequest):
    accountId: ObjectId | None = None


class MemorySourceCatalogRequest(MemorySnapshotRequest):
    serviceId: ObjectId
    expectedServiceRevision: Revision


class MemorySourceGrantRequest(MemorySourceCatalogRequest):
    accountId: ObjectId
    expectedAccountRevision: Revision
    expectedRevision: int = Field(ge=0, le=2**63 - 2)
    allowedAlbumIds: list[str] = Field(min_length=1, max_length=32)


class MemorySourceRevokeRequest(MemorySourceRequest):
    accountId: ObjectId
    expectedAccountRevision: Revision
    expectedRevision: int = Field(ge=0, le=2**63 - 2)


class MemoryFaceConsentRequest(MemorySourceRequest):
    accountId: None = None
    expectedRevision: Revision
    enabled: bool


class MemorySourceAlbum(StrictModel):
    albumId: str
    title: str = Field(min_length=1, max_length=256)


class MemorySourceService(StrictModel):
    serviceId: ObjectId
    serviceRevision: Revision
    name: str


class MemorySourceMember(StrictModel):
    accountId: ObjectId
    username: str
    revision: Revision


class MemorySourceState(MemoryVersioned):
    accountId: ObjectId
    accountRevision: Revision
    revision: int = Field(ge=0, le=2**63 - 2)
    membersRevision: Revision
    canManage: bool
    binding: MemoryBindingContract | None
    albums: list[MemorySourceAlbum] = Field(max_length=32)
    services: list[MemorySourceService] = Field(max_length=128)
    members: list[MemorySourceMember] = Field(max_length=32)


class MemorySourceResponse(StrictModel):
    requestId: ObjectId
    source: MemorySourceState


class MemorySourceCatalogResponse(StrictModel):
    requestId: ObjectId
    albums: list[MemorySourceAlbum] = Field(max_length=512)


class MemorySnapshotResponse(StrictModel):
    requestId: ObjectId
    snapshot: MemorySnapshot


class MemorySearchRequest(MemoryVersioned):
    requestId: ObjectId
    expectedMembersRevision: Revision
    serviceId: ObjectId
    expectedServiceRevision: Revision
    query: str = Field(min_length=1, max_length=256)
    albumIds: list[str] = Field(min_length=1, max_length=32)
    limit: int = Field(default=48, ge=1, le=100)
    language: str = Field(default="tr", pattern=r"^[a-z]{2,3}(?:-[A-Z]{2})?$")
    personIds: list[str] = Field(default_factory=list, max_length=16)
    takenAfter: str | None = Field(default=None, max_length=40)
    takenBefore: str | None = Field(default=None, max_length=40)


class MemorySearchResponse(StrictModel):
    requestId: ObjectId
    assets: list[MemoryAssetContract] = Field(max_length=100)


class CreateMemoryAlbumRequest(MemoryVersioned):
    requestId: ObjectId
    expectedMembersRevision: Revision
    title: str = Field(min_length=1, max_length=120)
    visibility: Literal["personal", "shared"]
    memberIds: list[ObjectId] = Field(min_length=1, max_length=32)
    serviceId: ObjectId
    expectedServiceRevision: Revision


class UpdateMemoryAlbumRequest(MemoryVersioned):
    requestId: ObjectId
    expectedMembersRevision: Revision
    expectedRevision: Revision
    title: str = Field(min_length=1, max_length=120)
    visibility: Literal["personal", "shared"]
    memberIds: list[ObjectId] = Field(min_length=1, max_length=32)


class ReplaceMemorySelectionsRequest(MemoryVersioned):
    requestId: ObjectId
    expectedMembersRevision: Revision
    expectedRevision: Revision
    serviceId: ObjectId
    expectedServiceRevision: Revision
    assets: list[MemorySelectionContract] = Field(max_length=250)


class ReconcileMemoryAlbumRequest(MemoryVersioned):
    requestId: ObjectId
    expectedMembersRevision: Revision
    expectedRevision: Revision
    serviceId: ObjectId
    expectedServiceRevision: Revision


class DeleteMemoryAlbumRequest(MemoryVersioned):
    requestId: ObjectId
    expectedMembersRevision: Revision
    expectedRevision: Revision


class MemoryAlbumResponse(StrictModel):
    requestId: ObjectId
    album: MemoryAlbumContract
