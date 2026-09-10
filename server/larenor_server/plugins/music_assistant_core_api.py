from typing import Annotated

from fastapi import APIRouter, Depends

from ..admin.models import ObjectId
from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .music_assistant_core_models import MusicAssistantCoreReadinessResponse


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    prefix='/admin/media/music-assistant',
    tags=['Managed Music Assistant Core'],
    responses={status: {'model': ErrorResponse}
               for status in (400, 401, 403, 404, 409, 503)})


@router.get('/{installation_id}', response_model=MusicAssistantCoreReadinessResponse)
def readiness(installation_id: ObjectId, core: Core, actor: Admin):
    return core.music_assistant_core.get(actor, installation_id)
