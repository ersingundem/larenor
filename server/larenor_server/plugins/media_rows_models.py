"""Secret-free account media rows returned by the privileged worker."""

import unicodedata
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from .stack_plan import MediaStackPlan
from .media_archive_core_models import MediaCatalogPage


class MediaRowItem(StrictModel):
    itemId: ObjectId
    title: str = Field(min_length=1, max_length=240)
    mediaKind: Literal["movie", "episode"]
    addedAt: int = Field(ge=1, le=253402300799)
    runtimeSeconds: int = Field(gt=0, le=604_800)
    positionSeconds: int = Field(ge=0, le=604_800)

    @field_validator("title")
    @classmethod
    def safe_title(cls, value):
        if value != value.strip() or any(
            unicodedata.category(character)[0] == "C" for character in value
        ):
            raise ValueError("invalid_media_row")
        return value

    @model_validator(mode="after")
    def coherent_position(self):
        if self.positionSeconds >= self.runtimeSeconds:
            raise ValueError("invalid_media_row")
        return self


class MediaRowsReadback(StrictModel):
    schemaVersion: Literal[1] = 1
    revision: Revision
    recent: list[MediaRowItem] = Field(max_length=24)
    resume: list[MediaRowItem] = Field(max_length=24)

    @model_validator(mode="after")
    def unique_lanes(self):
        for lane in (self.recent, self.resume):
            if len({item.itemId for item in lane}) != len(lane):
                raise ValueError("invalid_media_rows")
        if any(item.positionSeconds != 0 for item in self.recent) or any(
            not 0 < item.positionSeconds < item.runtimeSeconds for item in self.resume
        ):
            raise ValueError("invalid_media_rows")
        return self


class ReadAccountMediaRowsRequest(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    expectedBindingRevision: Revision


class ReadAccountMediaRowsTargetRequest(StrictModel):
    installationId: ObjectId
    expectedInstallationRevision: Revision


class ResolveAccountMediaRowRequest(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    expectedBindingRevision: Revision
    expectedSnapshotRevision: Revision
    expectedJellyfinServiceRevision: Revision
    itemId: ObjectId


class AccountMediaRowsTargetResponse(StrictModel):
    schemaVersion: Literal[1] = 1
    installationId: ObjectId
    installationRevision: Revision
    bindingRevision: Revision


class AccountMediaRowsResponse(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    installationRevision: Revision
    bindingRevision: Revision
    rows: MediaRowsReadback


class AccountMediaRowResolutionResponse(StrictModel):
    requestId: ObjectId
    bindingRevision: Revision
    catalog: MediaCatalogPage


class PrivateJellyfinMediaRowsAuthority(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    installationRevision: Revision
    bootstrapRevision: Revision
    bindingRevision: Revision
    plan: MediaStackPlan = Field(repr=False)
    apiKey: str = Field(
        min_length=32, max_length=128, pattern=r"^[A-Za-z0-9_-]+$", repr=False
    )
    userId: ObjectId = Field(repr=False)
