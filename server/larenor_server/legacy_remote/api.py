"""Admin-authenticated HTTP routes for opaque IR/RF controls."""

from typing import Annotated

from fastapi import APIRouter, Depends, Request

from ..auth import Principal
from ..dependencies import require_admin
from ..errors import ApiError
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import RemoteConfirmRequest, RemotePreviewRequest


Admin = Annotated[Principal, Depends(require_admin)]
ROOT = "/admin/legacy-remotes/{core_id}/{home_id}"


def exact_request(request: Request):
    if request.scope.get("query_string") or len(request.headers.getlist("authorization")) > 1:
        raise ApiError("invalid_request")


router = APIRouter(
    tags=["Legacy smart remotes"],
    dependencies=[Depends(exact_request)],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 429, 503)
    },
)


def _gateway(request: Request):
    gateway = getattr(request.app.state, "legacy_remote_gateway", None)
    if gateway is None:
        raise ApiError("remote_provider_unavailable", 503)
    return gateway


@router.get(ROOT)
def catalog(core_id: Identity, home_id: Identity, actor: Admin, request: Request):
    return {"catalog": _gateway(request).catalog(actor, core_id, home_id)}


@router.post(ROOT + "/previews", status_code=201)
def preview(
    core_id: Identity,
    home_id: Identity,
    body: RemotePreviewRequest,
    actor: Admin,
    request: Request,
):
    return {"preview": _gateway(request).preview(actor, core_id, home_id, body)}


@router.post(ROOT + "/previews/{request_id}/confirm")
def confirm(
    core_id: Identity,
    home_id: Identity,
    request_id: Identity,
    body: RemoteConfirmRequest,
    actor: Admin,
    request: Request,
):
    return {"result": _gateway(request).confirm(actor, core_id, home_id, request_id, body)}


@router.get(ROOT + "/results/{request_id}")
def result(
    core_id: Identity,
    home_id: Identity,
    request_id: Identity,
    actor: Admin,
    request: Request,
):
    return {"result": _gateway(request).result(actor, core_id, home_id, request_id)}
