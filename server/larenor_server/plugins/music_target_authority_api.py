from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .music_target_authority_models import (
    ConfirmMusicTargetCommandRequest, CreateMusicTargetCommandPreviewRequest,
    MusicTargetCommandPreviewResponse, MusicTargetCommandResponse,
    MusicTargetInventoryResponse, ReadMusicTargetInventoryRequest,
)


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    prefix='/admin/media/music-assistant/target-authority',
    tags=['Managed Music Assistant target authority'],
    responses={status: {'model': ErrorResponse}
               for status in (400, 401, 403, 404, 409, 503)},
)


@router.post('/inventory', response_model=MusicTargetInventoryResponse)
def inventory(body: ReadMusicTargetInventoryRequest, core: Core, actor: Admin):
    return core.music_target_authority.inventory(actor, body)


@router.post('/previews', response_model=MusicTargetCommandPreviewResponse,
             status_code=201)
def preview(body: CreateMusicTargetCommandPreviewRequest,
            core: Core, actor: Admin):
    return core.music_target_authority.preview(actor, body)


@router.post('/commands', response_model=MusicTargetCommandResponse,
             status_code=201)
def confirm(body: ConfirmMusicTargetCommandRequest, core: Core, actor: Admin):
    return core.music_target_authority.confirm(actor, body)
