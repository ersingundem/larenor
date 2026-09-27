"""Authenticated power-budget recommendation route."""

from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, ConfigDict, Field

from ..auth import Principal
from ..dependencies import require_admin
from ..errors import ApiError
from ..models import ErrorResponse

Admin = Annotated[Principal, Depends(require_admin)]


class ConfirmPowerBudget(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    schemaVersion: Literal[1]
    previewId: Annotated[str, Field(min_length=1, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")]
    expectedPlanHash: Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
    requestKey: Annotated[str, Field(min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")]


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


@router.post("/admin/power-budget/confirm")
def confirm(body: ConfirmPowerBudget, actor: Admin, request: Request):
    gateway = getattr(request.app.state, "power_budget_gateway", None)
    if gateway is None:
        raise ApiError("power_provider_unavailable", 503)
    return {
        "receipt": gateway.confirm(
            actor,
            preview_id=body.previewId,
            expected_plan_hash=body.expectedPlanHash,
            request_key=body.requestKey,
        )
    }
