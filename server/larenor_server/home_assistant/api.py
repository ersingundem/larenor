"""Admin-only binding confirmation and resource-authorized selected snapshots."""
import asyncio
from threading import Event
from typing import Annotated

from fastapi import APIRouter, Depends, Request, Response

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..errors import ApiError
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import BindingResponse, ConfirmRequest, PreviewRequest, PreviewResponse, SnapshotResponse

Core = Annotated[CoreServices, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
Ready = Annotated[Principal, Depends(require_ready_user)]


def exact_request(request: Request):
    if request.scope.get('query_string') or len(request.headers.getlist('authorization')) != 1:
        raise ApiError('invalid_request')


router = APIRouter(tags=['Selected Home Assistant switches'], dependencies=[Depends(exact_request)],
    responses={s: {'model': ErrorResponse} for s in (400, 401, 403, 404, 408, 409, 413, 429, 502, 503)})
PUBLIC = '/home-assistant/{core_id}/{home_id}/resources/{resource_id}'
ADMIN = '/admin' + PUBLIC


async def observe(request, operation):
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


@router.get(ADMIN + '/binding', response_model=BindingResponse)
def binding(core_id: Identity, home_id: Identity, resource_id: Identity, actor: Admin, core: Core):
    return core.home_assistant.binding(actor, core_id, home_id, resource_id)


@router.post(ADMIN + '/binding-preview', response_model=PreviewResponse, status_code=201)
async def preview(core_id: Identity, home_id: Identity, resource_id: Identity,
                  body: PreviewRequest, request: Request, actor: Admin, core: Core):
    return await observe(request, lambda cancelled: core.home_assistant.preview(
        actor, core_id, home_id, resource_id, body, cancelled=cancelled))


@router.post(ADMIN + '/binding-confirm', response_model=BindingResponse, status_code=201)
def confirm(core_id: Identity, home_id: Identity, resource_id: Identity,
            body: ConfirmRequest, actor: Admin, core: Core):
    return core.home_assistant.confirm(actor, core_id, home_id, resource_id, body.previewId)


@router.delete(ADMIN + '/binding-preview/{preview_id}', status_code=204)
def cancel(core_id: Identity, home_id: Identity, resource_id: Identity,
           preview_id: Identity, actor: Admin, core: Core):
    core.home_assistant.cancel_preview(actor, core_id, home_id, resource_id, preview_id)
    return Response(status_code=204)


@router.get(PUBLIC + '/snapshot', response_model=SnapshotResponse)
async def snapshot(core_id: Identity, home_id: Identity, resource_id: Identity,
                   request: Request, actor: Ready, core: Core):
    return await observe(request, lambda cancelled: core.home_assistant.snapshot(
        actor, core_id, home_id, resource_id, cancelled=cancelled))
