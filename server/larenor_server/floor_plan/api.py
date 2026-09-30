import asyncio
from threading import Event
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .api_models import (
    ActionRequest,
    ActionResponse,
    ExportResponse,
    EditorResponse,
    EditorReplaceRequest,
    HistoryResponse,
    LayoutModel,
    LayoutResponse,
    ReceiptModel,
    ReceiptResponse,
    ReplaceLayoutRequest,
)

Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
Limit = Annotated[int, Query(ge=1, le=1024)]
router = APIRouter(tags=["Interactive floor plan"], responses={
    status: {"model": ErrorResponse}
    for status in (400, 401, 403, 404, 408, 409, 413, 429, 502, 503)
})
ROOT = "/floor-plan/{core_id}/{home_id}"


@router.get(ROOT + "/editor", response_model=EditorResponse)
def editor(core_id: Identity, home_id: Identity, actor: Admin, core: Core):
    result = core.floor_plan.editor(actor, core_id, home_id)
    layout = result["layout"]
    return {**result, "layout": None if layout is None else LayoutModel.from_domain(layout)}


@router.put(ROOT + "/editor", response_model=ReceiptResponse)
def replace_editor(core_id: Identity, home_id: Identity, body: EditorReplaceRequest,
                   actor: Admin, core: Core):
    receipt = core.floor_plan.replace_editor(actor, core_id, home_id, body)
    return {"receipt": ReceiptModel(requestId=receipt.request_id,
                                    revision=receipt.revision, status=receipt.status)}


async def observe(request: Request, operation):
    cancelled = Event()

    async def monitor():
        while not cancelled.is_set():
            if await request.is_disconnected():
                cancelled.set()
                return
            await asyncio.sleep(0.05)

    watcher = asyncio.create_task(monitor())
    try:
        return await asyncio.to_thread(operation, cancelled.is_set)
    finally:
        cancelled.set()
        watcher.cancel()
        try:
            await watcher
        except asyncio.CancelledError:
            pass


@router.put(ROOT, response_model=ReceiptResponse)
def replace(core_id: Identity, home_id: Identity, body: ReplaceLayoutRequest,
            actor: Admin, core: Core):
    receipt = core.floor_plan.replace(actor, core_id, home_id, body)
    return {"receipt": ReceiptModel(
        requestId=receipt.request_id,
        revision=receipt.revision,
        status=receipt.status,
    )}


@router.get(ROOT, response_model=LayoutResponse)
async def read(core_id: Identity, home_id: Identity, request: Request,
               actor: Ready, core: Core):
    result = await observe(request, lambda cancelled: core.floor_plan.read(
        actor, core_id, home_id, cancelled=cancelled))
    stored, authority = result["stored"], result["authority"]
    return {
        "schemaVersion": 1,
        "layoutRevision": stored.revision,
        "entityRegistryRevision": authority.entity_registry_revision,
        "resourceRevision": authority.resource_revision,
        "grantRevision": authority.grant_revision,
        "layout": LayoutModel.from_domain(stored.layout),
        "projections": result["projections"],
        "projectionLimit": result["projectionLimit"],
        "projectionTruncated": result["projectionTruncated"],
    }


@router.post(ROOT + "/actions", response_model=ActionResponse, status_code=202)
async def action(core_id: Identity, home_id: Identity, body: ActionRequest,
                 request: Request, actor: Ready, core: Core):
    return await observe(request, lambda cancelled: core.floor_plan.action(
        actor, core_id, home_id, body, cancelled=cancelled))


@router.get(ROOT + "/export", response_model=ExportResponse)
def export(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    result = core.floor_plan.export(actor, core_id, home_id)
    return {**result, "layout": LayoutModel.from_domain(result["layout"])}


@router.get(ROOT + "/history", response_model=HistoryResponse)
def history(core_id: Identity, home_id: Identity, actor: Ready, core: Core,
            limit: Limit = 100):
    return {"entries": list(core.floor_plan.history(actor, core_id, home_id, limit))}
