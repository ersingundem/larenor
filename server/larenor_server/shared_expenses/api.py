from typing import Annotated

from fastapi import APIRouter, Depends, Response

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import CreateExpense, ExpectedLedger

Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    tags=["Shared household expenses"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 429, 503)
    },
)
ROOT = "/shared-expenses/{core_id}/{home_id}"


@router.get(ROOT)
def snapshot(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.shared_expenses.snapshot(actor, core_id, home_id)


@router.post(ROOT + "/commands/create", status_code=201)
def create(
    core_id: Identity, home_id: Identity, body: CreateExpense, actor: Ready, core: Core
):
    return core.shared_expenses.create(actor, core_id, home_id, body)


@router.get(ROOT + "/receipts/{command_id}")
def receipt(
    core_id: Identity,
    home_id: Identity,
    command_id: Identity,
    actor: Ready,
    core: Core,
    response: Response,
):
    value = core.shared_expenses.receipt(actor, core_id, home_id, command_id)
    if value is None:
        response.status_code = 204
    return value


@router.post(ROOT + "/export")
def export(
    core_id: Identity, home_id: Identity, body: ExpectedLedger, actor: Ready, core: Core
):
    return core.shared_expenses.export(actor, core_id, home_id, body)
