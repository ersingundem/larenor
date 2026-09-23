from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_ready_user
from ..models import ErrorResponse
from .media_playback_models import (
    MediaPlaybackCommandRequest,
    MediaPlaybackIntentResponse,
    MediaPlaybackReceiptResponse,
    PrepareMediaPlaybackIntentRequest,
)

Core = Annotated[object, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    prefix='/media/playback',
    tags=['Managed media playback'],
    responses={status: {'model': ErrorResponse}
               for status in (400, 401, 403, 404, 409, 503)},
)


@router.post('/intents', response_model=MediaPlaybackIntentResponse)
def prepare(body: PrepareMediaPlaybackIntentRequest, core: Core, actor: Ready):
    return core.media_playback.prepare(actor, body)


@router.post('/commands', response_model=MediaPlaybackReceiptResponse,
             status_code=201)
def command(body: MediaPlaybackCommandRequest, core: Core, actor: Ready):
    return core.media_playback.command(actor, body)
