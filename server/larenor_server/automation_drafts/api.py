from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import ActivateAutomationDraft, CreateAutomationDraft


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    tags=["Automation drafts"],
    responses={status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 409, 429, 503)},
)
ROOT = "/automation-drafts/{core_id}/{home_id}"


@router.get(ROOT + "/actions")
def actions(core_id: Identity, home_id: Identity, actor: Admin, core: Core):
    if (core_id, home_id) != (core.context.coreId, core.context.homeId):
        from ..errors import ApiError
        raise ApiError("not_found", 404)
    return {
        "schemaVersion": 1,
        "catalogVersion": "ha-switch-actions-v1",
        "actions": ["turn_on", "turn_off"],
        "deviceCommandAvailable": False,
    }


@router.post(ROOT, status_code=201)
def create(core_id: Identity, home_id: Identity, body: CreateAutomationDraft,
           actor: Admin, core: Core):
    return core.automation_drafts.create(actor, core_id, home_id, body)


@router.post(ROOT + "/{draft_id}/activation")
def activate(core_id: Identity, home_id: Identity, draft_id: Identity,
             body: ActivateAutomationDraft, actor: Admin, core: Core):
    return core.automation_drafts.activate(actor, core_id, home_id, draft_id, body)
