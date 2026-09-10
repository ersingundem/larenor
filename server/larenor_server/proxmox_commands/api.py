import asyncio
import re
import threading
from typing import Annotated

from fastapi import APIRouter, Depends, Request, Response

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin
from .discovery_models import TargetDiscoveryPage
from .models import ConfirmRequest, PreviewRequest


router = APIRouter(tags=["Proxmox power authority"])
Core = Annotated[CoreServices, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
PREFIX = "/admin/proxmox-power/{core_id}/{home_id}/{resource_id}"


def _target_query(request: Request):
    items = list(request.query_params.multi_items())
    allowed = {"limit", "after", "expectedSnapshot"}
    if (
        any(key not in allowed for key, _ in items)
        or len({key for key, _ in items}) != len(items)
    ):
        raise ValueError()
    values = dict(items)
    raw_limit = values.get("limit", "25")
    if (
        len(raw_limit) > 3
        or not raw_limit.isascii()
        or not raw_limit.isdigit()
        or str(int(raw_limit)) != raw_limit
    ):
        raise ValueError()
    limit = int(raw_limit)
    if not 1 <= limit <= 100:
        raise ValueError()
    after, snapshot = values.get("after"), values.get("expectedSnapshot")
    if (after is None) != (snapshot is None):
        raise ValueError()
    if after is not None and (
        re.fullmatch(r"[0-9a-f]{32}", after) is None
        or re.fullmatch(r"[0-9a-f]{64}", snapshot) is None
    ):
        raise ValueError()
    return limit, after, snapshot


@router.get(PREFIX + "/targets", response_model=TargetDiscoveryPage)
def targets(
    core_id: str,
    home_id: str,
    resource_id: str,
    request: Request,
    principal: Admin,
    core: Core,
):
    try:
        if len(request.headers.getlist("authorization")) != 1:
            raise ValueError()
        limit, after, snapshot = _target_query(request)
    except (TypeError, ValueError, OverflowError):
        from ..errors import ApiError

        raise ApiError("invalid_request") from None
    return core.proxmox_power.discover_targets(
        principal,
        core_id,
        home_id,
        resource_id,
        limit=limit,
        after=after,
        expected_snapshot=snapshot,
    )


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


@router.get(PREFIX + "/journal")
def journal(core_id: str, home_id: str, resource_id: str, principal: Admin,
            core: Core, limit: int = 50):
    return core.proxmox_power.journal(principal, core_id, home_id, resource_id, limit)


@router.get(PREFIX + "/journal/integrity")
def integrity(core_id: str, home_id: str, resource_id: str,
              principal: Admin, core: Core):
    return core.proxmox_power.journal_integrity(
        principal, core_id, home_id, resource_id)
