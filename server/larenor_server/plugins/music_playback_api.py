from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..admin.models import ObjectId
from ..dependencies import get_core, require_admin, require_ready_user
from ..models import ErrorResponse
from .music_playback_models import (
    MusicPlaybackCommandRequest, MusicPlaybackReceiptResponse,
    MusicPlaybackStateResponse, RefreshMusicPlaybackRequest,
)


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    prefix='/admin/media/music-assistant/playback',
    tags=['Managed Music Assistant playback'],
    responses={status: {'model': ErrorResponse}
               for status in (400, 401, 403, 404, 409, 503)})


@router.post('/refresh', response_model=MusicPlaybackStateResponse)
def refresh(body: RefreshMusicPlaybackRequest, core: Core, actor: Admin):
    return core.music_playback.refresh(actor, body)


@router.get('/{installation_id}', response_model=MusicPlaybackStateResponse)
def get(installation_id: ObjectId, core: Core, actor: Ready):
    return core.music_playback.get(actor, installation_id)


@router.post('/commands', response_model=MusicPlaybackReceiptResponse,
             status_code=201)
def command(body: MusicPlaybackCommandRequest, core: Core, actor: Admin):
    return core.music_playback.command(actor, body)
