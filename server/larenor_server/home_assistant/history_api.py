"""Resource-scoped command history; no provider calls or mutation endpoint."""
import re
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request

from ..errors import ApiError
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .api import Core, PUBLIC, Ready
from .models import CommandHistoryResponse


def exact_query(request: Request):
    pairs = list(request.query_params.multi_items())
    if (len(request.headers.getlist('authorization')) > 1 or len(pairs) > 2 or
            len({key for key, _ in pairs}) != len(pairs)):
        raise ApiError('invalid_request')
    for key, value in pairs:
        if key == 'before' and re.fullmatch('[0-9a-f]{32}', value):
            continue
        if key == 'limit' and re.fullmatch('[1-9][0-9]?', value) and int(value) <= 50:
            continue
        raise ApiError('invalid_request')


router = APIRouter(tags=['Attributed command history'], dependencies=[Depends(exact_query)],
    responses={s: {'model': ErrorResponse} for s in (400, 401, 403, 404, 429, 503)})


@router.get(PUBLIC + '/history', response_model=CommandHistoryResponse)
def history(core_id: Identity, home_id: Identity, resource_id: Identity, actor: Ready, core: Core,
            before: Identity | None = None, limit: Annotated[int, Query(ge=1, le=50)] = 25):
    return core.home_assistant.command_history(actor, core_id, home_id, resource_id, before=before, limit=limit)
