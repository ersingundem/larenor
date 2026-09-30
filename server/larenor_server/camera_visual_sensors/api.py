import asyncio
from threading import Event
from typing import Annotated

from fastapi import APIRouter, Depends, Request

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin
from ..home_resources.models import Identity
from ..models import ErrorResponse
from ..errors import ApiError
from .frigate import BindFrigateVisualSensor
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
    provider = core.camera_visual_sensors.provider
    return (core.camera_visual_sensors.summary(actor, core_id, home_id) if provider is None
            else provider.summary(actor, core_id, home_id))


@router.get(ROOT + "/sources")
def sources(core_id: Identity, home_id: Identity, actor: Admin, core: Core):
    return core.camera_visual_sensors.provider.sources(actor, core_id, home_id)


@router.put(ROOT + "/sources/{rule_id}", response_model=VisualSensorRuleResponse)
async def configure_source(core_id: Identity, home_id: Identity, rule_id: Identity,
    body: BindFrigateVisualSensor, request: Request, actor: Admin, core: Core):
    return await _observe(request, lambda cancelled: core.camera_visual_sensors.provider.configure(
        actor, core_id, home_id, rule_id, body, cancelled=cancelled))


@router.get(ROOT + "/sources/candidates/{camera_id}")
async def source_candidates(core_id: Identity, home_id: Identity, camera_id: Identity,
    request: Request, actor: Admin, core: Core):
    return await _observe(request, lambda cancelled: core.camera_visual_sensors.provider.candidates(
        actor, core_id, home_id, camera_id, cancelled=cancelled))


@router.post(ROOT + "/rules/{rule_id}/refresh", response_model=VisualSensorSummaryResponse)
async def refresh_source(core_id: Identity, home_id: Identity, rule_id: Identity,
    request: Request, actor: Admin, core: Core):
    return await _observe(request, lambda cancelled: core.camera_visual_sensors.provider.refresh(
        actor, core_id, home_id, rule_id, cancelled=cancelled))


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
    # Normal production observations must originate in the Core-owned provider.
    # An admin HTTP body is not evidence that any camera frame was classified.
    if core.camera_visual_sensors.provider is not None:
        raise ApiError("visual_sensor_observation_ingress_unsupported", 503)
    return await _observe(
        request,
        lambda cancelled: core.camera_visual_sensors.observe(
            actor, core_id, home_id, rule_id, body, cancelled=cancelled
        ),
    )
