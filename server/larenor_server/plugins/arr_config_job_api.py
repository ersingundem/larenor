"""Administrator API for durable Arr configuration jobs."""

from typing import Annotated

from fastapi import APIRouter, Depends, Query

from ..admin.models import ObjectId
from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .arr_config_job_models import (
    CancelArrConfigurationRequest,
    CreateArrConfigurationRequest,
    ArrConfigurationCapabilities, ArrConfigurationResponse,
    ArrConfigurationsResponse,
)


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    prefix='/admin/media/arr-configurations',
    tags=['Arr configuration jobs'],
    responses={status: {'model': ErrorResponse} for status in (400, 401, 403, 404, 409, 413, 503)},
)


@router.get('/capabilities', response_model=ArrConfigurationCapabilities)
def capabilities(core: Core, actor: Admin):
    return core.arr_configurations.capabilities(actor)


@router.post('', response_model=ArrConfigurationResponse, status_code=201)
def create(body: CreateArrConfigurationRequest, core: Core, actor: Admin):
    return core.arr_configurations.create(actor, body)


@router.get('', response_model=ArrConfigurationsResponse)
def list_configurations(core: Core, actor: Admin,
                        before: Annotated[int | None, Query(ge=1, le=2**63 - 1)] = None,
                        limit: Annotated[int, Query(ge=1, le=10)] = 10):
    return core.arr_configurations.list(actor, before=before, limit=limit)


@router.get('/{identifier}', response_model=ArrConfigurationResponse)
def get(identifier: ObjectId, core: Core, actor: Admin):
    return core.arr_configurations.get(actor, identifier)


@router.post('/{identifier}/cancel', response_model=ArrConfigurationResponse)
def cancel(identifier: ObjectId, body: CancelArrConfigurationRequest,
           core: Core, actor: Admin):
    return core.arr_configurations.cancel(actor, identifier, body)
