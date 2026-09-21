"""Admin-authenticated camera recording profile routes."""

from typing import Annotated

from fastapi import APIRouter, Depends, Request

from ..auth import Principal
from ..dependencies import require_admin
from ..errors import ApiError
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .http_models import CameraProfileApplyRequest

Admin = Annotated[Principal, Depends(require_admin)]
ROOT = "/admin/camera-profiles/{core_id}/{home_id}"


def exact_request(request: Request):
    if request.scope.get("query_string") or len(request.headers.getlist("authorization")) > 1:
        raise ApiError("invalid_request")


router = APIRouter(
    tags=["Camera recording profiles"],
    dependencies=[Depends(exact_request)],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 429, 503)
    },
)


def _gateway(request: Request):
    gateway = getattr(request.app.state, "camera_profile_gateway", None)
    if gateway is None:
        raise ApiError("camera_profile_provider_unavailable", 503)
    return gateway


@router.get(ROOT)
def snapshot(core_id: Identity, home_id: Identity, actor: Admin, request: Request):
    return {"snapshot": _gateway(request).snapshot(actor, core_id, home_id)}


@router.post(ROOT + "/apply")
def apply_profile(
    core_id: Identity,
    home_id: Identity,
    body: CameraProfileApplyRequest,
    actor: Admin,
    request: Request,
):
    return {"receipt": _gateway(request).apply(actor, core_id, home_id, body)}
