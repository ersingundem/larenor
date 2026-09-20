from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    CreateInventoryItem,
    CreatedInventoryItemResponse,
    InventoryItemResponse,
    InventoryQr,
)


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    tags=["Household inventory"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 429, 503)
    },
)
ROOT = "/inventory/{core_id}/{home_id}"


@router.post(ROOT + "/items", response_model=CreatedInventoryItemResponse, status_code=201)
def create_item(
    core_id: Identity,
    home_id: Identity,
    body: CreateInventoryItem,
    actor: Admin,
    core: Core,
):
    return core.inventory.create(actor, core_id, home_id, body)


@router.get(ROOT + "/items/{item_id}", response_model=InventoryItemResponse)
def get_item(
    core_id: Identity,
    home_id: Identity,
    item_id: Identity,
    actor: Ready,
    core: Core,
):
    return core.inventory.get(actor, core_id, home_id, item_id)


@router.post(ROOT + "/qr/resolve", response_model=InventoryItemResponse)
def resolve_qr(
    core_id: Identity,
    home_id: Identity,
    body: InventoryQr,
    actor: Ready,
    core: Core,
):
    return core.inventory.resolve(actor, core_id, home_id, body)
