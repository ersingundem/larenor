from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .api_models import (
    ConfirmEnergyCommand,
    EnergyPrioritySnapshot,
    PreviewEnergyCommand,
)
from .models import InverterCommandPreview, InverterCommandResult

Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
ROOT = "/energy-priorities/{core_id}/{home_id}"
router = APIRouter(
    tags=["Energy priorities"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 429, 503)
    },
)


@router.get(ROOT, response_model=EnergyPrioritySnapshot)
def snapshot(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.energy_priorities.snapshot(actor, core_id, home_id)


@router.post(ROOT + "/previews", status_code=201, response_model=InverterCommandPreview)
def preview(
    core_id: Identity,
    home_id: Identity,
    body: PreviewEnergyCommand,
    actor: Ready,
    core: Core,
):
    return core.energy_priorities.preview(actor, core_id, home_id, body)


@router.post(
    ROOT + "/previews/{request_id}/confirm",
    response_model=InverterCommandResult,
)
def confirm(
    core_id: Identity,
    home_id: Identity,
    request_id: Identity,
    body: ConfirmEnergyCommand,
    actor: Ready,
    core: Core,
):
    return core.energy_priorities.confirm(actor, core_id, home_id, request_id, body)


@router.get(ROOT + "/commands/{request_id}", response_model=InverterCommandResult)
def result(
    core_id: Identity,
    home_id: Identity,
    request_id: Identity,
    actor: Ready,
    core: Core,
):
    return core.energy_priorities.result(actor, core_id, home_id, request_id)
