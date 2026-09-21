from typing import Annotated

from fastapi import APIRouter, Depends, Response

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import CompleteChore, CreateChore, DeferChore

Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    tags=["Fair household chores"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 429, 503)
    },
)
ROOT = "/fair-chores/{core_id}/{home_id}"


@router.get(ROOT)
def list_chores(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.fair_chores.list(actor, core_id, home_id)


@router.post(ROOT, status_code=201)
def create_chore(
    core_id: Identity,
    home_id: Identity,
    body: CreateChore,
    actor: Ready,
    core: Core,
):
    return core.fair_chores.create(actor, core_id, home_id, body)


@router.post(ROOT + "/{task_id}/commands/complete")
def complete_chore(
    core_id: Identity,
    home_id: Identity,
    task_id: Identity,
    body: CompleteChore,
    actor: Ready,
    core: Core,
):
    return core.fair_chores.complete(actor, core_id, home_id, task_id, body)


@router.post(ROOT + "/{task_id}/commands/defer")
def defer_chore(
    core_id: Identity,
    home_id: Identity,
    task_id: Identity,
    body: DeferChore,
    actor: Ready,
    core: Core,
):
    return core.fair_chores.defer(actor, core_id, home_id, task_id, body)


@router.get(ROOT + "/receipts/{command_id}")
def receipt(
    core_id: Identity,
    home_id: Identity,
    command_id: Identity,
    actor: Ready,
    core: Core,
    response: Response,
):
    value = core.fair_chores.receipt(actor, core_id, home_id, command_id)
    if value is None:
        response.status_code = 204
    return value
