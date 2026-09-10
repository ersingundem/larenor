import asyncio
import threading
from typing import Annotated

from fastapi import APIRouter, Depends, Request, Response

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin
from .models import ConfirmRequest, PreviewRequest


router = APIRouter(tags=["Proxmox power authority"])
Core = Annotated[CoreServices, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
PREFIX = "/admin/proxmox-power/{core_id}/{home_id}/{resource_id}"


@router.post(PREFIX + "/previews", status_code=201)
def preview(core_id: str, home_id: str, resource_id: str, body: PreviewRequest,
            principal: Admin, core: Core):
    return core.proxmox_power.preview(principal, core_id, home_id, resource_id, body)


@router.delete(PREFIX + "/previews/{preview_id}", status_code=204)
def cancel(core_id: str, home_id: str, resource_id: str, preview_id: str,
           principal: Admin, core: Core):
    core.proxmox_power.cancel(principal, core_id, home_id, resource_id, preview_id)
    return Response(status_code=204)


@router.post(PREFIX + "/previews/{preview_id}/confirm")
async def confirm(core_id: str, home_id: str, resource_id: str, preview_id: str,
                  body: ConfirmRequest, principal: Admin, core: Core, request: Request):
    disconnected = threading.Event()
    stopped = asyncio.Event()

    async def monitor():
        while not stopped.is_set():
            if await request.is_disconnected():
                disconnected.set()
                return
            try:
                await asyncio.wait_for(stopped.wait(), timeout=0.025)
            except TimeoutError:
                pass

    task = asyncio.create_task(monitor())
    try:
        return await asyncio.to_thread(
            core.proxmox_power.confirm, principal, core_id, home_id, resource_id,
            preview_id, body, disconnected=disconnected.is_set)
    finally:
        stopped.set()
        await task


@router.get(PREFIX + "/results/{request_id}")
def result(core_id: str, home_id: str, resource_id: str, request_id: str,
           principal: Admin, core: Core):
    return core.proxmox_power.result(principal, core_id, home_id, resource_id, request_id)
