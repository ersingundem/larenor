from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .media_archive_core_models import (
    MediaArchiveReadRequest,
    MediaArchiveReadResponse,
)


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    prefix='/admin/media/archive-health',
    tags=['Media archive health'],
    responses={status: {'model': ErrorResponse}
               for status in (400, 401, 403, 404, 409, 503)},
)


@router.post('/read', response_model=MediaArchiveReadResponse)
def read(body: MediaArchiveReadRequest, core: Core, actor: Admin):
    return core.media_archive_health.read(actor, body)
