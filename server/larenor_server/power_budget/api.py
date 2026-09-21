"""Authenticated power-budget recommendation route."""

from typing import Annotated

from fastapi import APIRouter, Depends, Request

from ..auth import Principal
from ..dependencies import require_admin
from ..errors import ApiError
from ..models import ErrorResponse

Admin = Annotated[Principal, Depends(require_admin)]


def exact_request(request: Request):
    if request.scope.get("query_string") or len(request.headers.getlist("authorization")) > 1:
        raise ApiError("invalid_request")


router = APIRouter(
    tags=["Home power budget"],
    dependencies=[Depends(exact_request)],
    responses={status: {"model": ErrorResponse} for status in (400, 401, 403, 409, 413, 503)},
)


@router.get("/admin/power-budget")
def snapshot(actor: Admin, request: Request):
    gateway = getattr(request.app.state, "power_budget_gateway", None)
    if gateway is None:
        raise ApiError("power_provider_unavailable", 503)
    return {"snapshot": gateway.snapshot(actor)}
