from fastapi import APIRouter, Depends, Request

from ..home_resources.models import Identity
from .api import ADMIN, PUBLIC, Admin, Core, Ready, exact_request, observe
from .models import CommandResponse
from .rule_models import RuleCreateRequest, RuleExecuteRequest, RuleResponse


router = APIRouter(
    tags=['Attributed Home Assistant rules'],
    dependencies=[Depends(exact_request)],
)


@router.post(ADMIN + '/rules', response_model=RuleResponse, status_code=201)
def create_rule(
    core_id: Identity,
    home_id: Identity,
    resource_id: Identity,
    body: RuleCreateRequest,
    actor: Admin,
    core: Core,
):
    return core.home_assistant_rules.create(
        actor, core_id, home_id, resource_id, body
    )


@router.get(ADMIN + '/rules/{rule_id}', response_model=RuleResponse)
def get_rule(
    core_id: Identity,
    home_id: Identity,
    resource_id: Identity,
    rule_id: Identity,
    actor: Admin,
    core: Core,
):
    return core.home_assistant_rules.get(
        actor, core_id, home_id, resource_id, rule_id
    )


@router.post(
    PUBLIC + '/rules/{rule_id}/executions',
    response_model=CommandResponse,
    status_code=202,
)
async def execute_rule(
    core_id: Identity,
    home_id: Identity,
    resource_id: Identity,
    rule_id: Identity,
    body: RuleExecuteRequest,
    request: Request,
    actor: Ready,
    core: Core,
):
    return await observe(
        request,
        lambda cancelled: core.home_assistant_rules.execute(
            actor,
            core_id,
            home_id,
            resource_id,
            rule_id,
            body,
            cancelled=cancelled,
        ),
    )
