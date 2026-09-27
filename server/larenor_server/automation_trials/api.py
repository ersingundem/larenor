from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import CreateTrial, EvaluateTrialEvent, ReplayTrial


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    tags=["Automation trial weeks"],
    responses={status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 409, 429, 503)},
)
ROOT = "/automation-trials/{core_id}/{home_id}"


@router.get(ROOT)
def snapshot(core_id: Identity, home_id: Identity, actor: Admin, core: Core):
    return core.automation_trials.snapshot(actor, core_id, home_id)


@router.post(ROOT, status_code=201)
def create(core_id: Identity, home_id: Identity, body: CreateTrial, actor: Admin, core: Core):
    return core.automation_trials.create(actor, core_id, home_id, body)


@router.post(ROOT + "/{trial_id}/events", status_code=201)
def evaluate(core_id: Identity, home_id: Identity, trial_id: Identity,
             body: EvaluateTrialEvent, actor: Admin, core: Core):
    return core.automation_trials.evaluate(actor, core_id, home_id, trial_id, body)


@router.post(ROOT + "/{trial_id}/replays")
def replay(core_id: Identity, home_id: Identity, trial_id: Identity,
           body: ReplayTrial, actor: Admin, core: Core):
    return core.automation_trials.replay(actor, core_id, home_id, trial_id, body)
