from typing import Annotated

from fastapi import APIRouter, Depends

from ..admin.models import ObjectId, Revision
from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .music_provider_setup_models import (
    ActiveMusicProviderSetupResponse, ContinueMusicProviderSetupRequest,
    CreateMusicProviderSetupRequest, MusicProviderSetupCapabilities,
    MusicProviderSetupResponse, SubmitMusicProviderSetupRequest,
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


@router.get(
    '/installations/{installation_id}/revisions/{installation_revision}/requests/{request_id}',
    response_model=MusicProviderSetupResponse,
)
def get_by_request(installation_id: ObjectId, installation_revision: Revision,
                   request_id: ObjectId, core: Core, actor: Admin):
    return core.music_provider_setups.get_by_request(
        actor, installation_id, installation_revision, request_id)


@router.get(
    '/installations/{installation_id}/revisions/{installation_revision}/active',
    response_model=ActiveMusicProviderSetupResponse,
)
def get_active(installation_id: ObjectId, installation_revision: Revision,
               core: Core, actor: Admin):
    return core.music_provider_setups.get_active(
        actor, installation_id, installation_revision)


@router.get('/{identifier}', response_model=MusicProviderSetupResponse)
def get(identifier: ObjectId, core: Core, actor: Admin):
    return core.music_provider_setups.get(actor, identifier)


@router.post('/{identifier}/responses', response_model=MusicProviderSetupResponse)
def submit(identifier: ObjectId, body: SubmitMusicProviderSetupRequest,
           core: Core, actor: Admin):
    return core.music_provider_setups.submit(actor, identifier, body)


@router.post('/{identifier}/resume', response_model=MusicProviderSetupResponse)
def resume(identifier: ObjectId, body: ContinueMusicProviderSetupRequest,
           core: Core, actor: Admin):
    return core.music_provider_setups.resume(actor, identifier, body)


@router.post('/{identifier}/retry', response_model=MusicProviderSetupResponse)
def retry(identifier: ObjectId, body: ContinueMusicProviderSetupRequest,
          core: Core, actor: Admin):
    return core.music_provider_setups.retry(actor, identifier, body)


@router.post('/{identifier}/cancel', response_model=MusicProviderSetupResponse)
def cancel(identifier: ObjectId, body: ContinueMusicProviderSetupRequest,
           core: Core, actor: Admin):
    return core.music_provider_setups.cancel(actor, identifier, body)
