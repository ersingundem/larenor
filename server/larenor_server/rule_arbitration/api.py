"""HTTP boundary for Core-owned device-write arbitration."""

from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_admin, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    CompleteArbitratedIntent,
    ObserveExternalWrite,
    SubmitManualIntent,
    SubmitRuleIntent,
)


Core = Annotated[object, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    tags=["Rule arbitration"],
    responses={status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 409, 429, 503)},
)
ROOT = "/rule-arbitration/{core_id}/{home_id}"


@router.get(ROOT)
def snapshot(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.rule_arbitration.snapshot(actor, core_id, home_id)


@router.post(ROOT + "/rules")
def submit_rule(core_id: Identity, home_id: Identity, body: SubmitRuleIntent,
                actor: Ready, core: Core):
    return core.rule_arbitration.submit_rule(actor, core_id, home_id, body)


@router.post(ROOT + "/manual")
def submit_manual(core_id: Identity, home_id: Identity, body: SubmitManualIntent,
                  actor: Ready, core: Core):
    return core.rule_arbitration.submit_manual(actor, core_id, home_id, body)


@router.post(ROOT + "/decisions/{decision_id}/complete")
def complete(core_id: Identity, home_id: Identity, decision_id: Identity,
             body: CompleteArbitratedIntent, actor: Ready, core: Core):
    return core.rule_arbitration.complete(
        actor, core_id, home_id, decision_id, body
    )


@router.post(ROOT + "/external-observations")
def observe_external(core_id: Identity, home_id: Identity, body: ObserveExternalWrite,
                     actor: Admin, core: Core):
    return core.rule_arbitration.observe_external(actor, core_id, home_id, body)
