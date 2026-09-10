from typing import Annotated

from fastapi import APIRouter, Depends

from ..admin.models import ObjectId
from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .music_provider_setup_models import (
    CreateMusicProviderSetupRequest, MusicProviderSetupCapabilities,
    MusicProviderSetupResponse,
)


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    prefix='/admin/media/music-assistant/providers',
    tags=['Managed Music Assistant providers'],
    responses={status: {'model': ErrorResponse}
               for status in (400, 401, 403, 404, 409, 503)})


@router.get('/capabilities', response_model=MusicProviderSetupCapabilities)
def capabilities(core: Core, actor: Admin):
    return core.music_provider_setups.capabilities(actor)


@router.post('', response_model=MusicProviderSetupResponse, status_code=201)
def create(body: CreateMusicProviderSetupRequest, core: Core, actor: Admin):
    return core.music_provider_setups.create(actor, body)


@router.get('/{identifier}', response_model=MusicProviderSetupResponse)
def get(identifier: ObjectId, core: Core, actor: Admin):
    return core.music_provider_setups.get(actor, identifier)
