from typing import Annotated

from fastapi import APIRouter, Depends, Header

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..errors import ApiError
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import CreateSupportSession, RevokeSupportSession, SupportAccess, SupporterId


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    tags=["Time-limited support sessions"],
    responses={status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 409, 429, 503)},
)
ROOT = "/support-sessions/{core_id}/{home_id}"


@router.get(ROOT)
def sessions(core_id: Identity, home_id: Identity, actor: Admin, core: Core):
    return core.support_sessions.list(actor, core_id, home_id)


@router.post(ROOT, status_code=201)
def create_session(
    core_id: Identity, home_id: Identity, body: CreateSupportSession, actor: Admin, core: Core
):
    return core.support_sessions.create(actor, core_id, home_id, body)


@router.get(ROOT + "/{session_id}")
def session(core_id: Identity, home_id: Identity, session_id: Identity, actor: Admin, core: Core):
    return core.support_sessions.get(actor, core_id, home_id, session_id)


@router.post(ROOT + "/{session_id}/revoke")
def revoke_session(
    core_id: Identity, home_id: Identity, session_id: Identity,
    body: RevokeSupportSession, actor: Admin, core: Core,
):
    return core.support_sessions.revoke(actor, core_id, home_id, session_id, body)


@router.post(ROOT + "/access")
def access(
    core_id: Identity,
    home_id: Identity,
    body: SupportAccess,
    core: Core,
    authorization: Annotated[str | None, Header()] = None,
    supporter_id: Annotated[SupporterId | None, Header(alias="X-Larenor-Supporter")] = None,
):
    if authorization is None or not authorization.startswith("Bearer ") or supporter_id is None:
        raise ApiError("invalid_support_token", 401)
    return core.support_sessions.access(authorization[7:], supporter_id, core_id, home_id, body)
