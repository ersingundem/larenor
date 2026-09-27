from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    CancelCookingSessionRequest,
    CookingSessionListResponse,
    CookingSessionResponse,
    CreateCookingSessionRequest,
    MoveCookingSessionRequest,
    IngredientDeductionRequest,
    IngredientDeductionResponse,
)


Core = Annotated[object, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    tags=["Cooking assistant"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 429, 503)
    },
)
ROOT = "/cooking/sessions"


def _response(session):
    return {"schemaVersion": 1, "session": session.contract()}


@router.get(ROOT, response_model=CookingSessionListResponse)
def list_sessions(actor: Ready, core: Core):
    return {
        "schemaVersion": 1,
        "sessions": tuple(item.contract() for item in core.cooking.list(actor)),
    }


@router.post(ROOT, response_model=CookingSessionResponse, status_code=201)
def create_session(body: CreateCookingSessionRequest, actor: Ready, core: Core):
    return _response(
        core.cooking.create(
            actor,
            recipe_id=body.recipeId,
            recipe_revision=body.recipeRevision,
            title=body.title,
            steps=body.steps,
        )
    )


@router.get(ROOT + "/{session_id}", response_model=CookingSessionResponse)
def get_session(session_id: str, actor: Ready, core: Core):
    return _response(core.cooking.get(actor, session_id))


@router.put(ROOT + "/{session_id}/step", response_model=CookingSessionResponse)
def move_session(
    session_id: str,
    body: MoveCookingSessionRequest,
    actor: Ready,
    core: Core,
):
    return _response(
        core.cooking.move(
            actor,
            session_id,
            expected_revision=body.expectedRevision,
            step=body.step,
        )
    )


@router.post(ROOT + "/{session_id}/cancel", response_model=CookingSessionResponse)
def cancel_session(
    session_id: str,
    body: CancelCookingSessionRequest,
    actor: Ready,
    core: Core,
):
    return _response(
        core.cooking.cancel(
            actor,
            session_id,
            expected_revision=body.expectedRevision,
        )
    )


@router.post(
    "/cooking/{core_id}/{home_id}/sessions/{session_id}/ingredient-deductions",
    response_model=IngredientDeductionResponse,
)
def deduct_ingredients(
    core_id: Identity,
    home_id: Identity,
    session_id: str,
    body: IngredientDeductionRequest,
    actor: Ready,
    core: Core,
):
    return core.cooking.deduct_ingredients(actor, session_id, core_id, home_id, body)


@router.get(
    "/cooking/{core_id}/{home_id}/sessions/{session_id}/ingredient-deductions/"
    "{idempotency_key}",
    response_model=IngredientDeductionResponse,
)
def ingredient_receipt(
    core_id: Identity,
    home_id: Identity,
    session_id: str,
    idempotency_key: str,
    actor: Ready,
    core: Core,
):
    return core.cooking.ingredient_receipt(
        actor, session_id, idempotency_key, core_id, home_id
    )
