"""Audiobook and podcast listening session boundary."""

from typing import Annotated

from fastapi import APIRouter, Depends

from ..admin.models import ObjectId
from ..auth import Principal
from ..dependencies import get_core, require_ready_user
from ..models import ErrorResponse
from .models import (LongformSessionResponse, OpenLongformSessionRequest,
                     UpdateLongformSessionRequest)

Core = Annotated[object, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    prefix="/media/longform", tags=["Long-form media"],
    responses={status: {"model": ErrorResponse}
               for status in (400, 401, 403, 404, 409, 503)},
)


@router.post("/sessions/open", response_model=LongformSessionResponse,
             status_code=201)
def open_session(body: OpenLongformSessionRequest, core: Core, actor: Ready):
    return core.longform_sessions.open(actor, body)


@router.post("/sessions/{session_id}",
             response_model=LongformSessionResponse)
def update_session(session_id: ObjectId, body: UpdateLongformSessionRequest,
                   core: Core, actor: Ready):
    return core.longform_sessions.update(actor, session_id, body)
