from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Query

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    SoundEventAcknowledgement,
    SoundEventAcknowledgementRequest,
    SoundEventFeedbackReceipt,
    SoundEventFeedbackRequest,
    SoundEventPolicyReceipt,
    SoundEventPolicyRequest,
    SoundEventSnapshot,
)

Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Limit = Annotated[int, Query(ge=1, le=100)]
SafeClass = Literal["bark", "noise"]
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


@router.put(ROOT + "/policy", response_model=SoundEventPolicyReceipt)
def update_policy(
    core_id: Identity,
    home_id: Identity,
    body: SoundEventPolicyRequest,
    actor: Ready,
    core: Core,
):
    return core.sound_events.update_policy(actor, core_id, home_id, body)


@router.post(
    ROOT + "/{event_id}/feedback", response_model=SoundEventFeedbackReceipt
)
def feedback(
    core_id: Identity,
    home_id: Identity,
    event_id: Identity,
    body: SoundEventFeedbackRequest,
    actor: Ready,
    core: Core,
):
    return core.sound_events.feedback(actor, core_id, home_id, event_id, body)
