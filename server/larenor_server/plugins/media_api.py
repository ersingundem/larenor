from typing import Annotated

from fastapi import APIRouter, Depends, Query

from ..admin.models import ObjectId
from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .media_models import (CancelMediaPreparationRequest, CreateMediaPreparationRequest,
                           MediaPreparationResponse, MediaPreparationsResponse)


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(prefix="/admin/media/preparations", tags=["Integrated media preparations"], responses={
    status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 409, 413, 503)
})


@router.post("", response_model=MediaPreparationResponse, status_code=201)
def create(body: CreateMediaPreparationRequest, core: Core, actor: Admin):
    return core.media_preparations.create(actor, body)


@router.get("", response_model=MediaPreparationsResponse)
def list_preparations(core: Core, actor: Admin,
                      before: Annotated[int | None, Query(ge=1, le=2**63 - 1)] = None,
                      limit: Annotated[int, Query(ge=1, le=10)] = 10):
    return core.media_preparations.list(actor, before=before, limit=limit)


@router.get("/{preparation_id}", response_model=MediaPreparationResponse)
def get(preparation_id: ObjectId, core: Core, actor: Admin):
    return core.media_preparations.get(actor, preparation_id)


@router.post("/{preparation_id}/cancel", response_model=MediaPreparationResponse)
def cancel(preparation_id: ObjectId, body: CancelMediaPreparationRequest, core: Core, actor: Admin):
    return core.media_preparations.cancel(actor, preparation_id, body)
