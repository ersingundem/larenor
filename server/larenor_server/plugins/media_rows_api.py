from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_ready_user
from ..models import ErrorResponse
from .media_rows_models import (
    AccountMediaRowsResponse,
    ReadAccountMediaRowsRequest,
)


Core = Annotated[object, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    prefix='/media/rows',
    tags=['Account media rows'],
    responses={status: {'model': ErrorResponse}
               for status in (400, 401, 403, 409, 503)},
)


@router.post('/read', response_model=AccountMediaRowsResponse)
def read(body: ReadAccountMediaRowsRequest, core: Core, actor: Ready):
    return core.media_rows.read(actor, body)
