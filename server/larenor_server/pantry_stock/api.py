from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (ConsumeStockRequest, PantryMutationResponse,
                     PantrySnapshotResponse, ReceiveStockRequest,
                     UndoStockRequest)


Core = Annotated[object, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    tags=['Pantry stock'],
    responses={status: {'model': ErrorResponse}
               for status in (400, 401, 403, 404, 409, 429, 503)},
)
ROOT = '/pantry/{core_id}/{home_id}'


@router.get(ROOT, response_model=PantrySnapshotResponse)
def snapshot(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.pantry_stock.snapshot(actor, core_id, home_id)


@router.post(ROOT + '/receive', response_model=PantryMutationResponse,
             status_code=201)
def receive(core_id: Identity, home_id: Identity, body: ReceiveStockRequest,
            actor: Ready, core: Core):
    return core.pantry_stock.receive(actor, core_id, home_id, body)


@router.post(ROOT + '/consume', response_model=PantryMutationResponse)
def consume(core_id: Identity, home_id: Identity, body: ConsumeStockRequest,
            actor: Ready, core: Core):
    return core.pantry_stock.consume(actor, core_id, home_id, body)


@router.post(ROOT + '/undo', response_model=PantryMutationResponse)
def undo(core_id: Identity, home_id: Identity, body: UndoStockRequest,
         actor: Ready, core: Core):
    return core.pantry_stock.undo(actor, core_id, home_id, body)
