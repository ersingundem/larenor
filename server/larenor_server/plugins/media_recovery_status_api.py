from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .media_recovery_status_models import MediaRecoveryStatusResponse


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    prefix="/admin/media/recovery-status",
    tags=["Managed media recovery status"],
    responses={status: {"model": ErrorResponse}
               for status in (400, 401, 403, 409, 503)},
)


@router.get("", response_model=MediaRecoveryStatusResponse)
def recovery_status(core: Core, actor: Admin):
    return core.media_recovery_status.read(actor)
