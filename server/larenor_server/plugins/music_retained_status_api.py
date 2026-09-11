from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .music_retained_status_models import MusicRetainedStatusResponse


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    prefix='/admin/media/music-assistant/retained',
    tags=['Retained Music Assistant status'],
    responses={status: {'model': ErrorResponse}
               for status in (400, 401, 403, 409, 503)})


@router.get('', response_model=MusicRetainedStatusResponse)
def retained_status(core: Core, actor: Admin):
    return core.music_retained_status.read(actor)
