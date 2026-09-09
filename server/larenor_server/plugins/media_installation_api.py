from typing import Annotated

from fastapi import APIRouter, Depends, Query

from ..admin.models import ObjectId
from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .media_installation_models import (
    CancelMediaInstallationRequest, CreateMediaInstallationRequest,
    MediaInstallationCapabilities, MediaInstallationResponse, MediaInstallationsResponse,
)


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(prefix='/admin/media/installations', tags=['Bounded media installation execution'], responses={
    status: {'model': ErrorResponse} for status in (400, 401, 403, 404, 409, 413, 503)
})


@router.get('/capabilities', response_model=MediaInstallationCapabilities)
def capabilities(core: Core, actor: Admin):
    return core.media_installations.capabilities(actor)


@router.post('', response_model=MediaInstallationResponse, status_code=201)
def create(body: CreateMediaInstallationRequest, core: Core, actor: Admin):
    return core.media_installations.create(actor, body)


@router.get('', response_model=MediaInstallationsResponse)
def list_installations(core: Core, actor: Admin,
                       before: Annotated[int | None, Query(ge=1, le=2**63 - 1)] = None,
                       limit: Annotated[int, Query(ge=1, le=10)] = 10):
    return core.media_installations.list(actor, before=before, limit=limit)


@router.get('/{identifier}', response_model=MediaInstallationResponse)
def get(identifier: ObjectId, core: Core, actor: Admin):
    return core.media_installations.get(actor, identifier)


@router.post('/{identifier}/cancel', response_model=MediaInstallationResponse)
def cancel(identifier: ObjectId, body: CancelMediaInstallationRequest, core: Core, actor: Admin):
    return core.media_installations.cancel(actor, identifier, body)
