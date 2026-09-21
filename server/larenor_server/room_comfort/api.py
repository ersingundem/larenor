from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .api_models import (
    ComfortPlanResponse,
    ComfortPreviewResponse,
    ComfortReceiptResponse,
    ConfirmComfortPlan,
    PreviewComfortPlan,
    PublishComfortPlan,
)


Core = Annotated[CoreServices, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
ROOT = "/room-comfort/{core_id}/{home_id}"
router = APIRouter(tags=["Room comfort"], responses={
    status: {"model": ErrorResponse}
    for status in (400, 401, 403, 404, 409, 429, 503)
})


@router.put(ROOT + "/plan", response_model=ComfortPlanResponse)
def publish(core_id: Identity, home_id: Identity, body: PublishComfortPlan,
            actor: Admin, core: Core):
    return core.room_comfort.publish(actor, core_id, home_id, body)


@router.get(ROOT + "/plan", response_model=ComfortPlanResponse)
def current(core_id: Identity, home_id: Identity, actor: Admin, core: Core):
    return core.room_comfort.current(actor, core_id, home_id)


@router.post(ROOT + "/previews", status_code=201,
             response_model=ComfortPreviewResponse)
def preview(core_id: Identity, home_id: Identity, body: PreviewComfortPlan,
            actor: Admin, core: Core):
    return core.room_comfort.preview(actor, core_id, home_id, body)


@router.post(ROOT + "/previews/{preview_id}/confirm", status_code=201,
             response_model=ComfortReceiptResponse)
def confirm(core_id: Identity, home_id: Identity, preview_id: Identity,
            body: ConfirmComfortPlan, actor: Admin, core: Core):
    return core.room_comfort.confirm(actor, core_id, home_id, preview_id, body)
