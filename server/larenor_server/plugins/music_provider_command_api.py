from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .music_provider_command_models import (
    ConfirmMusicProviderCommandRequest, CreateMusicProviderCommandPreviewRequest,
    MusicProviderCommandPreviewResponse, MusicProviderCommandResponse,
)

Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    prefix='/admin/media/music-assistant/provider-commands',
    tags=['Managed Music Assistant provider commands'],
    responses={status: {'model': ErrorResponse} for status in (400, 401, 403, 409, 503)},
)


@router.post('/previews', response_model=MusicProviderCommandPreviewResponse, status_code=201)
def preview(body: CreateMusicProviderCommandPreviewRequest, core: Core, actor: Admin):
    return core.music_provider_commands.preview(actor, body)


@router.post('', response_model=MusicProviderCommandResponse, status_code=201)
def confirm(body: ConfirmMusicProviderCommandRequest, core: Core, actor: Admin):
    return core.music_provider_commands.confirm(actor, body)
