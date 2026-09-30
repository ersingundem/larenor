"""Versioned HTTP boundary for authorized live television recording."""

from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_admin, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    LiveTvSnapshotResponse,
    JellyfinSourceConfigurationRequest,
    JellyfinSourceOptionsResponse,
    RecordingInterruptionRequest,
    RecordingMutationRequest,
    RecordingRequest,
    RecordingResponse,
    SourceSnapshotRequest,
)

Core = Annotated[object, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    prefix="/media/live-tv",
    tags=["Live television"],
    responses={status: {"model": ErrorResponse}
               for status in (400, 401, 403, 404, 409, 429, 503)},
)


@router.get("", response_model=LiveTvSnapshotResponse)
def read_live_tv(core: Core, actor: Ready):
    return core.live_tv.read(actor)


@router.put("/source", response_model=LiveTvSnapshotResponse)
def configure_source(body: SourceSnapshotRequest, core: Core, actor: Admin):
    return core.live_tv.configure(actor, body)


@router.get("/source-options", response_model=JellyfinSourceOptionsResponse)
def source_options(core: Core, actor: Admin):
    return core.live_tv.source_options(actor)


@router.put("/jellyfin-source", response_model=LiveTvSnapshotResponse)
def configure_jellyfin_source(
    body: JellyfinSourceConfigurationRequest, core: Core, actor: Admin
):
    return core.live_tv.configure_jellyfin(actor, body)


@router.post("/recordings", response_model=RecordingResponse, status_code=201)
def schedule_recording(body: RecordingRequest, core: Core, actor: Ready):
    return core.live_tv.schedule(actor, body)


@router.post("/recordings/{recording_id}/cancel", response_model=RecordingResponse)
def cancel_recording(
    recording_id: Identity,
    body: RecordingMutationRequest,
    core: Core,
    actor: Ready,
):
    return core.live_tv.cancel(actor, recording_id, body)


@router.post("/recordings/{recording_id}/restart", response_model=RecordingResponse)
def restart_recording(
    recording_id: Identity,
    body: RecordingMutationRequest,
    core: Core,
    actor: Ready,
):
    return core.live_tv.restart(actor, recording_id, body)


@router.post("/recordings/{recording_id}/interrupt", response_model=RecordingResponse)
def interrupt_recording(
    recording_id: Identity,
    body: RecordingInterruptionRequest,
    core: Core,
    actor: Admin,
):
    return core.live_tv.interrupt(actor, recording_id, body)
