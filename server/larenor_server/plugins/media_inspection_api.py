from typing import Annotated

from fastapi import APIRouter, Depends, Query

from ..admin.models import ObjectId
from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .media_inspection_models import (CancelMediaInspectionRequest, CreateMediaInspectionRequest,
                                      MediaInspectionCapabilities, MediaInspectionResponse,
                                      MediaInspectionsResponse)


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(prefix='/admin/media/inspections', tags=['Integrated media inspections'], responses={
    status: {'model': ErrorResponse} for status in (400, 401, 403, 404, 409, 413, 503)
})


@router.get('/capabilities', response_model=MediaInspectionCapabilities)
def capabilities(core: Core, actor: Admin):
    return core.media_inspections.capabilities(actor)


@router.post('', response_model=MediaInspectionResponse, status_code=201)
def create(body: CreateMediaInspectionRequest, core: Core, actor: Admin):
    return core.media_inspections.create(actor, body)


@router.get('', response_model=MediaInspectionsResponse)
def list_inspections(core: Core, actor: Admin,
                     before: Annotated[int | None, Query(ge=1, le=2**63 - 1)] = None,
                     limit: Annotated[int, Query(ge=1, le=10)] = 10):
    return core.media_inspections.list(actor, before=before, limit=limit)


@router.get('/{inspection_id}', response_model=MediaInspectionResponse)
def get(inspection_id: ObjectId, core: Core, actor: Admin):
    return core.media_inspections.get(actor, inspection_id)


@router.post('/{inspection_id}/cancel', response_model=MediaInspectionResponse)
def cancel(inspection_id: ObjectId, body: CancelMediaInspectionRequest, core: Core, actor: Admin):
    return core.media_inspections.cancel(actor, inspection_id, body)
