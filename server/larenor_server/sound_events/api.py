from typing import Annotated, Literal
import threading

import anyio
from fastapi import APIRouter, Depends, Query, Request

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
from .source_models import (
    FrigateSoundSourceInput,
    SoundSourceRefresh,
    SoundSourceSetup,
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


@router.get(ROOT + "/source", response_model=SoundSourceSetup)
def source(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    core.auth.rate_limit([("sound_source_read", actor.id, 60)])
    return core.sound_event_source.setup(actor, core_id, home_id)


@router.post(ROOT + "/source/discovery", response_model=SoundSourceSetup)
def discover_source(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    core.auth.rate_limit([("sound_source_discovery", actor.id, 20)])
    return core.sound_event_source.discover(actor, core_id, home_id)


@router.put(ROOT + "/source", response_model=SoundSourceSetup)
def configure_source(
    core_id: Identity,
    home_id: Identity,
    body: FrigateSoundSourceInput,
    actor: Ready,
    core: Core,
):
    core.auth.rate_limit([("sound_source_configuration", actor.id, 20)])
    core.sound_event_source.configure(actor, core_id, home_id, body)
    return core.sound_event_source.setup(actor, core_id, home_id)


@router.post(ROOT + "/source/refresh", response_model=SoundSourceRefresh)
async def refresh_source(
    request: Request,
    core_id: Identity,
    home_id: Identity,
    actor: Ready,
    core: Core,
):
    core.auth.rate_limit([("sound_source_refresh", actor.id, 30)])
    cancelled, done = threading.Event(), threading.Event()

    async def watch_disconnect():
        while not done.is_set():
            if await request.is_disconnected():
                cancelled.set()
                return
            await anyio.sleep(0.02)

    async with anyio.create_task_group() as tasks:
        tasks.start_soon(watch_disconnect)
        try:
            return await anyio.to_thread.run_sync(
                lambda: core.sound_event_source.refresh(
                    actor, core_id, home_id, cancelled=cancelled.is_set
                ),
                abandon_on_cancel=True,
            )
        except BaseException:
            cancelled.set()
            raise
        finally:
            done.set()
            tasks.cancel_scope.cancel()


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
