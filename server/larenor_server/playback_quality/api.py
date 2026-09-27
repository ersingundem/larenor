from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import PlaybackQualityAdviceRequest, PlaybackQualityAdviceResponse


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
ROOT = "/media/playback-quality/{core_id}/{home_id}/advice"
router = APIRouter(
    tags=["Playback quality advice"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 429, 503)
    },
)


@router.post(ROOT, response_model=PlaybackQualityAdviceResponse)
def advise(
    core_id: Identity,
    home_id: Identity,
    body: PlaybackQualityAdviceRequest,
    actor: Ready,
    core: Core,
):
    return core.playback_quality.advise(actor, core_id, home_id, body)
