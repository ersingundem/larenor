from typing import Annotated

from fastapi import APIRouter, Depends, Query

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    SoundEventAcknowledgement,
    SoundEventAcknowledgementRequest,
    SoundEventSnapshot,
)

Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Limit = Annotated[int, Query(ge=1, le=100)]
SafeClass = Annotated[str, Query(min_length=1, max_length=48)]
router = APIRouter(
    tags=["Sound events"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 429, 503)
    },
)
ROOT = "/sound-events/{core_id}/{home_id}"


@router.get(ROOT, response_model=SoundEventSnapshot)
def events(
    core_id: Identity,
    home_id: Identity,
    actor: Ready,
    core: Core,
    roomId: Identity | None = None,
    className: SafeClass | None = None,
    acknowledged: bool | None = None,
    limit: Limit = 100,
):
    return core.sound_events.list(
        actor,
        core_id,
        home_id,
        room_id=roomId,
        class_name=className,
        acknowledged=acknowledged,
        limit=limit,
    )


@router.post(
    ROOT + "/{event_id}/acknowledgements",
    response_model=SoundEventAcknowledgement,
)
def acknowledge(
    core_id: Identity,
    home_id: Identity,
    event_id: Identity,
    body: SoundEventAcknowledgementRequest,
    actor: Ready,
    core: Core,
):
    return core.sound_events.acknowledge(actor, core_id, home_id, event_id, body)
