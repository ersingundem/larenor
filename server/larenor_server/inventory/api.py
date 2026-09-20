from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    CreateInventoryItem,
    CreatedInventoryItemResponse,
    InventoryItemResponse,
    InventoryItemsPage,
    InventoryGrantsResponse,
    InventoryHistoryResponse,
    InventoryQr,
    SetInventoryGrant,
    UpdateInventoryItem,
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


@router.get(ROOT + "/items", response_model=InventoryItemsPage)
def list_items(
    core_id: Identity,
    home_id: Identity,
    actor: Ready,
    core: Core,
    limit: int = Query(default=25, ge=1, le=100),
    cursor: str | None = Query(default=None, min_length=1, max_length=512),
):
    return core.inventory.list_items(
        actor,
        core_id,
        home_id,
        limit=limit,
        cursor=cursor,
    )


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


@router.patch(ROOT + "/items/{item_id}", response_model=InventoryItemResponse)
def update_item(core_id: Identity, home_id: Identity, item_id: Identity,
                body: UpdateInventoryItem, actor: Admin, core: Core):
    return core.inventory.update(actor, core_id, home_id, item_id, body)


@router.get(ROOT + "/items/{item_id}/grants", response_model=InventoryGrantsResponse)
def grants(core_id: Identity, home_id: Identity, item_id: Identity,
           actor: Admin, core: Core):
    return core.inventory.grants(actor, core_id, home_id, item_id)


@router.put(ROOT + "/items/{item_id}/grants/{subject_id}", response_model=InventoryItemResponse)
def set_grant(core_id: Identity, home_id: Identity, item_id: Identity,
              subject_id: Identity, body: SetInventoryGrant, actor: Admin, core: Core):
    return core.inventory.set_grant(actor, core_id, home_id, item_id, subject_id, body)


@router.delete(ROOT + "/items/{item_id}/grants/{subject_id}", status_code=204)
def revoke_grant(core_id: Identity, home_id: Identity, item_id: Identity,
                 subject_id: Identity, body: SetInventoryGrant, actor: Admin, core: Core):
    core.inventory.set_grant(actor, core_id, home_id, item_id, subject_id, body, revoke=True)
    return Response(status_code=204)


@router.get(ROOT + "/items/{item_id}/history", response_model=InventoryHistoryResponse)
def history(core_id: Identity, home_id: Identity, item_id: Identity,
            actor: Ready, core: Core):
    return core.inventory.history(actor, core_id, home_id, item_id)
