from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    CreateShareRequest,
    PreviewRequest,
    RedeemShareRequest,
    RevokeShareRequest,
)

Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    tags=["Private event sharing"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 429, 503)
    },
)
ROOT = "/private-event-sharing/{core_id}/{home_id}/{camera_id}/{event_id}"


@router.get(ROOT + "/context")
def context(
    core_id: Identity,
    home_id: Identity,
    camera_id: Identity,
    event_id: Identity,
    actor: Ready,
    core: Core,
):
    return core.private_event_sharing.context(
        actor, core_id, home_id, camera_id, event_id
    )


@router.get(ROOT)
def snapshot(
    core_id: Identity,
    home_id: Identity,
    camera_id: Identity,
    event_id: Identity,
    actor: Ready,
    core: Core,
    limit: int = Query(256, ge=1, le=256),
):
    return core.private_event_sharing.snapshot(
        actor, core_id, home_id, camera_id, event_id, limit
    )


@router.post(ROOT + "/preview")
def preview(
    core_id: Identity,
    home_id: Identity,
    camera_id: Identity,
    event_id: Identity,
    body: PreviewRequest,
    actor: Ready,
    core: Core,
):
    return core.private_event_sharing.preview(
        actor, core_id, home_id, camera_id, event_id, body
    )


@router.post(ROOT + "/shares", status_code=201)
def create(
    core_id: Identity,
    home_id: Identity,
    camera_id: Identity,
    event_id: Identity,
    body: CreateShareRequest,
    actor: Ready,
    core: Core,
):
    return core.private_event_sharing.create(
        actor, core_id, home_id, camera_id, event_id, body
    )


@router.post(ROOT + "/revoke")
def revoke(
    core_id: Identity,
    home_id: Identity,
    camera_id: Identity,
    event_id: Identity,
    body: RevokeShareRequest,
    actor: Ready,
    core: Core,
):
    return core.private_event_sharing.revoke(
        actor, core_id, home_id, camera_id, event_id, body
    )


@router.post(ROOT + "/download")
def download(
    core_id: Identity,
    home_id: Identity,
    camera_id: Identity,
    event_id: Identity,
    body: RedeemShareRequest,
    actor: Ready,
    core: Core,
):
    value = core.private_event_sharing.download(
        actor,
        core_id,
        home_id,
        camera_id,
        event_id,
        body.accessId,
        body.accessToken,
    )
    return Response(
        content=value.content,
        media_type="application/octet-stream",
        headers={
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "Content-Disposition": f'attachment; filename="event-{value.share_id}.bin"',
            "X-Larenor-Content-SHA256": value.digest,
        },
    )
