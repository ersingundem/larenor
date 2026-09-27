"""Authenticated irrigation planning and verified valve control routes."""

import asyncio
from threading import Event
from typing import Annotated

from fastapi import APIRouter, Depends, Request

from ..auth import Principal
from ..dependencies import require_admin
from ..errors import ApiError
from ..models import ErrorResponse
from .models import (
    IrrigationConfirmRequest,
    IrrigationPreviewRequest,
    IrrigationStopRequest,
)

Admin = Annotated[Principal, Depends(require_admin)]


def exact_request(request: Request):
    if request.scope.get("query_string") or len(request.headers.getlist("authorization")) > 1:
        raise ApiError("invalid_request")


router = APIRouter(
    tags=["Garden irrigation"],
    dependencies=[Depends(exact_request)],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 408, 409, 429, 503)
    },
)


@router.get("/admin/irrigation-budget")
def snapshot(actor: Admin, request: Request):
    gateway = getattr(request.app.state, "irrigation_gateway", None)
    if gateway is None:
        raise ApiError("irrigation_provider_unavailable", 503)
    return {"snapshot": gateway.snapshot(actor)}


def _gateway(request):
    gateway = getattr(request.app.state, "irrigation_gateway", None)
    if gateway is None:
        raise ApiError("irrigation_provider_unavailable", 503)
    return gateway


@router.post("/admin/irrigation-budget/preview")
def preview(body: IrrigationPreviewRequest, actor: Admin, request: Request):
    return {"schemaVersion": 1, "preview": _gateway(request).preview(actor, body)}


async def _disconnectable(request, operation):
    cancelled = Event()

    async def watch():
        while not cancelled.is_set():
            if await request.is_disconnected():
                cancelled.set()
                return
            await asyncio.sleep(0.05)

    watcher = asyncio.create_task(watch())
    try:
        return await asyncio.to_thread(operation, cancelled.is_set)
    finally:
        cancelled.set()
        watcher.cancel()


@router.post("/admin/irrigation-budget/confirm")
async def confirm(body: IrrigationConfirmRequest, actor: Admin, request: Request):
    gateway = _gateway(request)
    receipt = await _disconnectable(
        request,
        lambda cancelled: gateway.confirm(actor, body, cancelled=cancelled),
    )
    return {"schemaVersion": 1, "receipt": receipt}


@router.post("/admin/irrigation-budget/stop")
def stop(body: IrrigationStopRequest, actor: Admin, request: Request):
    return {"schemaVersion": 1, "receipt": _gateway(request).stop(actor, body)}
