from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import MealPlanResponse, PutMealPlanRequest


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    tags=['Weekly meal plans'],
    responses={status: {'model': ErrorResponse}
               for status in (400, 401, 403, 404, 409, 413, 429, 503)},
)
ROOT = '/meal-plans/{core_id}/{home_id}'


@router.get(ROOT, response_model=MealPlanResponse)
def get_plan(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.meal_plans.get(actor, core_id, home_id)


@router.put(ROOT, response_model=MealPlanResponse)
def put_plan(core_id: Identity, home_id: Identity, body: PutMealPlanRequest,
             actor: Ready, core: Core):
    return core.meal_plans.put(actor, core_id, home_id, body)
