from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..models import ErrorResponse
from .models import Identity, MultiDisplayProjection
from .service import read_authority


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    tags=["External displays"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 429, 503)
    },
)


@router.get(
    "/multi-display/{core_id}/{home_id}/authority",
    response_model=MultiDisplayProjection,
)
def authority(
    core_id: Identity,
    home_id: Identity,
    actor: Ready,
    core: Core,
):
    return read_authority(core, actor, core_id, home_id)
