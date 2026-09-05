from typing import Literal

from pydantic import Field

from ..admin.models import ObjectId
from ..context import ContextResponse
from ..models import StrictModel
from .models import Digest, Platform
from .stack_plan import MediaStackPlan, MediaStackSettings


class CreateMediaPreparationRequest(StrictModel):
    requestId: ObjectId
    templateId: Literal["media"]
    context: ContextResponse
    catalogDigest: Digest
    platform: Platform
    settings: MediaStackSettings


class CancelMediaPreparationRequest(StrictModel):
    expectedRevision: int = Field(ge=1, le=2)


class MediaPreparation(StrictModel):
    id: ObjectId
    requestId: ObjectId
    revision: int = Field(ge=1, le=2)
    state: Literal["prepared", "cancelled"]
    createdAt: str
    updatedAt: str
    catalogCurrent: bool
    plan: MediaStackPlan


class MediaPreparationResponse(StrictModel):
    preparation: MediaPreparation


class MediaPreparationsResponse(StrictModel):
    preparations: list[MediaPreparation] = Field(max_length=10)
    nextBefore: int | None = Field(ge=1, le=2**63 - 1)


class MediaPreparationPayload(StrictModel):
    request: CreateMediaPreparationRequest
    plan: MediaStackPlan
