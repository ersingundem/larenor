"""Member-readable, secret-free Music Assistant target discovery."""

from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_ready_user
from ..models import ErrorResponse
from .music_target_authority_models import (
    MusicTargetInventoryResponse, ReadMusicTargetInventoryRequest,
)


Core = Annotated[object, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    prefix='/media/music-assistant/target-discovery',
    tags=['Managed Music Assistant target discovery'],
    responses={status: {'model': ErrorResponse}
               for status in (400, 401, 403, 404, 409, 503)},
)


@router.post('', response_model=MusicTargetInventoryResponse)
def discovery(body: ReadMusicTargetInventoryRequest,
              core: Core, actor: Ready):
    return core.music_target_authority.discovery(actor, body)
