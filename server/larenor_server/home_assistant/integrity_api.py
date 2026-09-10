"""Admin-only read verification and export of a caller-retained checkpoint."""
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Query, Request
from pydantic import Field

from ..errors import ApiError
from ..home_resources.models import FrozenModel, HomeScope, Identity, Snapshot
from ..models import ErrorResponse
from .api import Admin, Core
from .command_chain import MAX_ENTRIES


class Verification(FrozenModel):
    schemaVersion: Literal[1] = 1
    scope: HomeScope
    chainId: Identity
    sequence: Annotated[int, Field(ge=0, le=MAX_ENTRIES)]
    headHash: Snapshot
    checkpoint: Annotated[str, Field(max_length=512)]
    verified: Literal[True]
    comparedCheckpoint: bool
    causalityVerified: Literal[False]


class VerificationResponse(FrozenModel):
    verification: Verification


def exact_query(request: Request):
    pairs = list(request.query_params.multi_items())
    if (len(request.headers.getlist('authorization')) > 1 or len(pairs) > 1 or
            any(key != 'checkpoint' for key, _ in pairs)):
        raise ApiError('invalid_request')


router = APIRouter(tags=['Command history integrity'], dependencies=[Depends(exact_query)],
    responses={s: {'model': ErrorResponse} for s in (400, 401, 403, 404, 409, 429, 503)})


@router.get('/admin/home-assistant/{core_id}/{home_id}/history/verification', response_model=VerificationResponse)
def verification(core_id: Identity, home_id: Identity, actor: Admin, core: Core,
                 checkpoint: Annotated[str | None, Query(max_length=512)] = None):
    return core.home_assistant.verify_history(actor, core_id, home_id, checkpoint=checkpoint)
