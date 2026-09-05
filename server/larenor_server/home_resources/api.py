from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..models import ErrorResponse
from .api_models import (CreateRecordRequest, GrantResponse, GrantsResponse, ListResponse,
                         RecordResponse, SetGrantRequest, UpdateRecordRequest)
from .models import Identity


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
Limit = Annotated[int, Query(ge=1, le=100)]
Expected = Annotated[int, Query(ge=1, le=2**63 - 1)]
router = APIRouter(tags=['Home resource registry'], responses={
    status: {'model': ErrorResponse} for status in (400, 401, 403, 404, 409, 413, 429, 503)})
PUBLIC = '/home-resources/{core_id}/{home_id}'
ADMIN = '/admin' + PUBLIC


@router.get(PUBLIC, response_model=ListResponse)
def records(core_id: Identity, home_id: Identity, actor: Ready, core: Core,
            after: Identity | None = None, expectedRegistryRevision: Expected | None = None, limit: Limit = 25):
    return core.home_resources.list(actor, core_id, home_id, after=after,
        expected_registry_revision=expectedRegistryRevision, limit=limit)


@router.get(PUBLIC + '/{record_id}', response_model=RecordResponse)
def record(core_id: Identity, home_id: Identity, record_id: Identity, actor: Ready, core: Core):
    return core.home_resources.get(actor, core_id, home_id, record_id)


@router.post(ADMIN, response_model=RecordResponse, status_code=201)
def create(core_id: Identity, home_id: Identity, body: CreateRecordRequest, actor: Admin, core: Core):
    return core.home_resources.create(actor, core_id, home_id, body)


@router.patch(ADMIN + '/{record_id}', response_model=RecordResponse)
def update(core_id: Identity, home_id: Identity, record_id: Identity,
           body: UpdateRecordRequest, actor: Admin, core: Core):
    return core.home_resources.update(actor, core_id, home_id, record_id, body)


@router.delete(ADMIN + '/{record_id}', status_code=204)
def delete(core_id: Identity, home_id: Identity, record_id: Identity,
           expectedRevision: Expected, expectedAclRevision: Expected, actor: Admin, core: Core):
    core.home_resources.delete(actor, core_id, home_id, record_id, expectedRevision, expectedAclRevision)
    return Response(status_code=204)


@router.get(ADMIN + '/{record_id}/grants', response_model=GrantsResponse)
def grants(core_id: Identity, home_id: Identity, record_id: Identity, actor: Admin, core: Core):
    return core.home_resources.grants(actor, core_id, home_id, record_id)


@router.put(ADMIN + '/{record_id}/grants/{subject_id}', response_model=GrantResponse)
def set_grant(core_id: Identity, home_id: Identity, record_id: Identity, subject_id: Identity,
              body: SetGrantRequest, actor: Admin, core: Core):
    return core.home_resources.set_grant(actor, core_id, home_id, record_id, subject_id, body)
