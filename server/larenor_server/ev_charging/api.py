from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .http_models import ConfirmCharge, PreviewCharge

Core = Annotated[CoreServices, Depends(get_core)]
User = Annotated[Principal, Depends(require_ready_user)]
ROOT = "/ev-charging/{core_id}/{home_id}"
router = APIRouter(
    tags=["EV charging"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 503)
    },
)


@router.get(ROOT + "/capability")
def capability(core_id: Identity, home_id: Identity, actor: User, core: Core):
    return core.ev_charging.capability(actor, core_id, home_id)


@router.post(ROOT + "/chargers/{charger_id}/previews", status_code=201)
def preview(
    core_id: Identity,
    home_id: Identity,
    charger_id: Identity,
    body: PreviewCharge,
    actor: User,
    core: Core,
):
    return core.ev_charging.preview(actor, core_id, home_id, charger_id, body)


@router.post(ROOT + "/chargers/{charger_id}/commands", status_code=201)
def confirm(
    core_id: Identity,
    home_id: Identity,
    charger_id: Identity,
    body: ConfirmCharge,
    actor: User,
    core: Core,
):
    return core.ev_charging.confirm(actor, core_id, home_id, charger_id, body)
