from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..errors import ApiError
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    CreateShareRequest,
    PreviewRequest,
    RedeemShareRequest,
    RevokeShareRequest,
    AcceptEventConsentRequest,
    PrivateEventPolicyRequest,
)
from .provider import CorePrivateEventSharingProvider

Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    tags=["Private event sharing"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 429, 503)
    },
)
ROOT = "/private-event-sharing/{core_id}/{home_id}/{camera_id}/{event_id}"


def _provider(core: CoreServices) -> CorePrivateEventSharingProvider:
    value = getattr(core, "private_event_share_provider", None)
    if not isinstance(value, CorePrivateEventSharingProvider):
        raise ApiError("share_unavailable", 503)
    return value


@router.get("/admin/private-event-sharing/{core_id}/{home_id}/policy")
def sharing_policy(core_id: Identity, home_id: Identity, actor: Admin, core: Core):
    return _provider(core).policy(actor, core_id, home_id)


@router.put("/admin/private-event-sharing/{core_id}/{home_id}/policy")
def configure_sharing_policy(
    core_id: Identity,
    home_id: Identity,
    body: PrivateEventPolicyRequest,
    actor: Admin,
    core: Core,
):
    core.auth.rate_limit([("private_event_policy", actor.id, 30)])
    return _provider(core).configure_policy(
        actor,
        core_id,
        home_id,
        {
            "expected_revision": body.expectedRevision,
            "active": body.active,
            "grantor_ids": body.grantorIds,
            "recipient_ids": body.recipientIds,
            "purposes": body.purposes,
            "access_modes": body.accessModes,
            "max_ttl_seconds": body.maxTtlSeconds,
            "required_masks": body.requiredMasks,
            "required_metadata": body.requiredMetadata,
            "redaction_mode": body.redactionMode,
        },
    )


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


@router.post(ROOT + "/consents", status_code=201)
def accept_consent(
    core_id: Identity,
    home_id: Identity,
    camera_id: Identity,
    event_id: Identity,
    body: AcceptEventConsentRequest,
    actor: Ready,
    core: Core,
):
    if (core_id, home_id) != (core.context.coreId, core.context.homeId):
        raise ApiError("not_found", 404)
    core.auth.rate_limit([("private_event_consent", actor.id, 30)])
    return _provider(core).accept_consent(
        actor,
        camera_id,
        event_id,
        {
            "authority": {
                "coreRevision": body.coreRevision,
                "homeRevision": body.homeRevision,
                "accountRevision": body.accountRevision,
                "membersRevision": body.membersRevision,
                "cameraRevision": body.cameraRevision,
                "eventRevision": body.eventRevision,
                "sessionRevision": body.sessionRevision,
                "expectedShareRevision": body.expectedShareRevision,
            },
            "expected_policy_revision": body.expectedPolicyRevision,
            "recipient_id": body.recipientId,
            "purpose": body.purpose,
            "expires_at": body.expiresAt,
            "access_mode": body.accessMode,
            "masks": body.masks,
            "removed_metadata": body.removedMetadata,
        },
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
