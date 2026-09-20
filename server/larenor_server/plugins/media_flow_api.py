from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .media_flow_models import (
    MediaFlowAuthorityRequest,
    MediaFlowAuthorityResponse,
    MediaFlowReadRequest,
    MediaFlowReadResponse,
)


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    prefix="/admin/media/flows",
    tags=["Managed media flows"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 409, 503)
    },
)


@router.post("/authority", response_model=MediaFlowAuthorityResponse)
def authority(body: MediaFlowAuthorityRequest, core: Core, actor: Admin):
    return core.media_flow.authority(actor, body)


@router.post("/read", response_model=MediaFlowReadResponse)
def read(body: MediaFlowReadRequest, core: Core, actor: Admin):
    return core.media_flow.read(actor, body)
