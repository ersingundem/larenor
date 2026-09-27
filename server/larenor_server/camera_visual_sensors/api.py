import asyncio
from threading import Event
from typing import Annotated

from fastapi import APIRouter, Depends, Request

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .http_models import (
    ConfigureVisualSensorRule,
    SubmitVisualSensorObservation,
    VisualSensorObservationResponse,
    VisualSensorRuleResponse,
    VisualSensorSummaryResponse,
)


Core = Annotated[CoreServices, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
ROOT = "/camera-visual-sensors/{core_id}/{home_id}"
router = APIRouter(
    tags=["Camera visual sensors"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 408, 409, 429, 503)
    },
)


@router.put(ROOT + "/rules/{rule_id}", response_model=VisualSensorRuleResponse)
def configure(
    core_id: Identity,
    home_id: Identity,
    rule_id: Identity,
    body: ConfigureVisualSensorRule,
    actor: Admin,
    core: Core,
):
    return core.camera_visual_sensors.configure(actor, core_id, home_id, rule_id, body)


@router.get(ROOT + "/summary", response_model=VisualSensorSummaryResponse)
def summary(core_id: Identity, home_id: Identity, actor: Admin, core: Core):
    return core.camera_visual_sensors.summary(actor, core_id, home_id)


async def _observe(request, operation):
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


@router.post(
    ROOT + "/rules/{rule_id}/observations",
    response_model=VisualSensorObservationResponse,
)
async def observe(
    core_id: Identity,
    home_id: Identity,
    rule_id: Identity,
    body: SubmitVisualSensorObservation,
    request: Request,
    actor: Admin,
    core: Core,
):
    return await _observe(
        request,
        lambda cancelled: core.camera_visual_sensors.observe(
            actor, core_id, home_id, rule_id, body, cancelled=cancelled
        ),
    )
