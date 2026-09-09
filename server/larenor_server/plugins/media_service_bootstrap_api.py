"""Admin-only public status API for private media bootstrap intent."""

from typing import Annotated

from fastapi import APIRouter, Depends, Query

from ..admin.models import ObjectId
from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .media_service_bootstrap_models import (
    CreateMediaServiceBootstrapRequest, MediaServiceBootstrapResponse,
    MediaServiceBootstrapsResponse,
)


router = APIRouter(prefix='/admin/media/bootstraps', tags=['Managed media bootstrap'],
                   responses={400: {'model': ErrorResponse}, 401: {'model': ErrorResponse},
                              403: {'model': ErrorResponse}, 404: {'model': ErrorResponse},
                              409: {'model': ErrorResponse}, 503: {'model': ErrorResponse}})
Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]


@router.post('', status_code=201, response_model=MediaServiceBootstrapResponse)
def create(body: CreateMediaServiceBootstrapRequest, actor: Admin, core: Core):
    return core.media_service_bootstraps.create(actor, body)


@router.get('', response_model=MediaServiceBootstrapsResponse)
def list_bootstraps(actor: Admin, core: Core,
                    before: Annotated[int | None, Query(ge=1, le=2**63 - 1)] = None,
                    limit: Annotated[int, Query(ge=1, le=10)] = 10):
    return core.media_service_bootstraps.list(actor, before=before, limit=limit)


@router.get('/{identifier}', response_model=MediaServiceBootstrapResponse)
def get(identifier: ObjectId, actor: Admin, core: Core):
    return core.media_service_bootstraps.get(actor, identifier)
