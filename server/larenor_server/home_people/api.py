from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..models import ErrorResponse
from .models import (CreatePersonRequest, PersonGrantResponse, PersonGrantsResponse, PeopleResponse,
                         PersonResponse, SetPersonGrantRequest, UpdatePersonRequest)
from .models import Identity, Snapshot


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
Limit = Annotated[int, Query(ge=1, le=100)]
Expected = Annotated[int, Query(ge=1, le=2**63 - 1)]
router = APIRouter(tags=['Household profiles'], responses={
    status: {'model': ErrorResponse} for status in (400, 401, 403, 404, 409, 413, 429, 503)})
PUBLIC = '/home-people/{core_id}/{home_id}'
ADMIN = '/admin' + PUBLIC


@router.get(PUBLIC, response_model=PeopleResponse)
def records(core_id: Identity, home_id: Identity, actor: Ready, core: Core,
            after: Identity | None = None, expectedSnapshot: Snapshot | None = None, limit: Limit = 25):
    return core.home_people.list(actor, core_id, home_id, after=after,
        expected_snapshot=expectedSnapshot, limit=limit)


@router.get(PUBLIC + '/{record_id}', response_model=PersonResponse)
def record(core_id: Identity, home_id: Identity, record_id: Identity, actor: Ready, core: Core):
    return core.home_people.get(actor, core_id, home_id, record_id)


@router.post(ADMIN, response_model=PersonResponse, status_code=201)
def create(core_id: Identity, home_id: Identity, body: CreatePersonRequest, actor: Admin, core: Core):
    return core.home_people.create(actor, core_id, home_id, body)


@router.patch(ADMIN + '/{record_id}', response_model=PersonResponse)
def update(core_id: Identity, home_id: Identity, record_id: Identity,
           body: UpdatePersonRequest, actor: Admin, core: Core):
    return core.home_people.update(actor, core_id, home_id, record_id, body)


@router.delete(ADMIN + '/{record_id}', status_code=204)
def delete(core_id: Identity, home_id: Identity, record_id: Identity,
           expectedRevision: Expected, expectedAclRevision: Expected, actor: Admin, core: Core):
    core.home_people.delete(actor, core_id, home_id, record_id, expectedRevision, expectedAclRevision)
    return Response(status_code=204)


@router.get(ADMIN + '/{record_id}/grants', response_model=PersonGrantsResponse)
def grants(core_id: Identity, home_id: Identity, record_id: Identity, actor: Admin, core: Core):
    return core.home_people.grants(actor, core_id, home_id, record_id)


@router.put(ADMIN + '/{record_id}/grants/{subject_id}', response_model=PersonGrantResponse)
def set_grant(core_id: Identity, home_id: Identity, record_id: Identity, subject_id: Identity,
              body: SetPersonGrantRequest, actor: Admin, core: Core):
    return core.home_people.set_grant(actor, core_id, home_id, record_id, subject_id, body)
