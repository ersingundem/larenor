from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..admin.models import ObjectId
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .music_target_authority_models import (
    CancelMusicTargetCommandRequest, ConfirmMusicTargetCommandRequest,
    CreateMusicTargetCommandPreviewRequest, MusicTargetCommandPreviewResponse,
    MusicTargetCommandResponse, MusicTargetHistoryRequest,
    MusicTargetHistoryResponse, MusicTargetIntegrityResponse,
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


@router.get('/commands/{identifier}', response_model=MusicTargetCommandResponse)
def status(identifier: ObjectId, core: Core, actor: Admin):
    return core.music_target_authority.get_command(actor, identifier)


@router.post('/commands/{identifier}/cancel',
             response_model=MusicTargetCommandResponse)
def cancel(identifier: ObjectId, body: CancelMusicTargetCommandRequest,
           core: Core, actor: Admin):
    return core.music_target_authority.cancel(actor, identifier, body)


@router.post('/history', response_model=MusicTargetHistoryResponse)
def history(body: MusicTargetHistoryRequest, core: Core, actor: Admin):
    return core.music_target_authority.history(actor, body)


@router.post('/integrity', response_model=MusicTargetIntegrityResponse)
def integrity(body: ReadMusicTargetInventoryRequest, core: Core, actor: Admin):
    return core.music_target_authority.integrity(actor, body)
