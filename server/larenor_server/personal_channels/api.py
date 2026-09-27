"""HTTP boundary for Core-owned personal television channels."""

from typing import Annotated

from fastapi import APIRouter, Depends, Query

from ..auth import Principal
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    ChannelListResponse,
    ChannelSnapshotResponse,
    CreateChannelRequest,
    ExpectedChannelRequest,
    PlaybackSourceResponse,
    RescheduleProgrammeRequest,
    ResolveProgrammeRequest,
)

Core = Annotated[object, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    prefix="/media/personal-channels", tags=["Personal channels"],
    responses={status: {"model": ErrorResponse}
               for status in (400, 401, 403, 404, 409, 429, 503)},
)


@router.get("", response_model=ChannelListResponse)
def list_channels(core: Core, actor: Ready):
    return core.personal_channels.list(actor)


@router.post("", response_model=ChannelSnapshotResponse, status_code=201)
def create_channel(body: CreateChannelRequest, core: Core, actor: Ready):
    return core.personal_channels.create(actor, body)


@router.get("/{channel_id}", response_model=ChannelSnapshotResponse)
def read_channel(
    channel_id: Identity,
    core: Core,
    actor: Ready,
    guide_from: int | None = Query(default=None, alias="from", ge=1),
    guide_until: int | None = Query(default=None, alias="until", ge=2),
):
    return core.personal_channels.read(
        actor, channel_id, guide_from, guide_until)


@router.post(
    "/{channel_id}/programmes/{programme_id}/reschedule",
    response_model=ChannelSnapshotResponse,
)
def reschedule_programme(
    channel_id: Identity,
    programme_id: Identity,
    body: RescheduleProgrammeRequest,
    core: Core,
    actor: Ready,
):
    return core.personal_channels.reschedule(
        actor, channel_id, programme_id, body)


@router.post("/{channel_id}/cancel", response_model=ChannelSnapshotResponse)
def cancel_channel(
    channel_id: Identity,
    body: ExpectedChannelRequest,
    core: Core,
    actor: Ready,
):
    return core.personal_channels.cancel(actor, channel_id, body)


@router.post(
    "/{channel_id}/playback", response_model=PlaybackSourceResponse,
)
def resolve_playback(
    channel_id: Identity,
    body: ResolveProgrammeRequest,
    core: Core,
    actor: Ready,
):
    return core.personal_channels.resolve(actor, channel_id, body)
