from typing import Annotated

from fastapi import APIRouter, Depends, Query

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    CreatePersonalProfileRequest,
    PersonalProfileDeletionResponse,
    PersonalProfileResponse,
    PersonalProfilesResponse,
    UpdatePersonalProfileRequest,
)

Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Expected = Annotated[int, Query(ge=1, le=2**63 - 1)]
ExpectedCollection = Annotated[int, Query(ge=0, le=2**63 - 1)]
router = APIRouter(tags=['Core remote profiles'], responses={
    status: {'model': ErrorResponse}
    for status in (400, 401, 403, 404, 409, 413, 429, 503)
})
BASE = '/core-remote-profiles/{core_id}/{home_id}'


@router.get(BASE, response_model=PersonalProfilesResponse)
def profiles(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.personal_profiles.list(actor, core_id, home_id)


@router.get(BASE + '/{profile_id}', response_model=PersonalProfileResponse)
def profile(core_id: Identity, home_id: Identity, profile_id: Identity,
            expectedRevision: Expected,
            expectedCollectionRevision: ExpectedCollection,
            expectedAccountRevision: Expected,
            actor: Ready, core: Core):
    return core.personal_profiles.get(
        actor, core_id, home_id, profile_id, expectedRevision,
        expectedCollectionRevision, expectedAccountRevision)


@router.post(BASE, response_model=PersonalProfileResponse, status_code=201)
def create_profile(core_id: Identity, home_id: Identity,
                   body: CreatePersonalProfileRequest, actor: Ready, core: Core):
    return core.personal_profiles.create(actor, core_id, home_id, body)


@router.patch(BASE + '/{profile_id}', response_model=PersonalProfileResponse)
def update_profile(core_id: Identity, home_id: Identity, profile_id: Identity,
                   body: UpdatePersonalProfileRequest, actor: Ready, core: Core):
    return core.personal_profiles.update(actor, core_id, home_id, profile_id, body)


@router.delete(
    BASE + '/{profile_id}', response_model=PersonalProfileDeletionResponse)
def delete_profile(core_id: Identity, home_id: Identity, profile_id: Identity,
                   requestId: Identity, expectedRevision: Expected,
                   expectedCollectionRevision: ExpectedCollection,
                   expectedAccountRevision: Expected,
                   actor: Ready, core: Core):
    return core.personal_profiles.delete(
        actor, core_id, home_id, profile_id, expectedRevision,
        expectedCollectionRevision, expectedAccountRevision, requestId)
