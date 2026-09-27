"""Admin-only endpoint for a caller-retained Core audit checkpoint."""

from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin
from ..errors import ApiError
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import CoreAuditVerificationResponse


Core = Annotated[CoreServices, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]


def exact_query(request: Request) -> None:
    pairs = list(request.query_params.multi_items())
    if (
        len(request.headers.getlist("authorization")) > 1
        or len(pairs) > 1
        or any(key != "checkpoint" for key, _ in pairs)
    ):
        raise ApiError("invalid_request")


router = APIRouter(
    tags=["Core audit integrity"],
    dependencies=[Depends(exact_query)],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 429, 503)
    },
)


@router.get(
    "/admin/core-audit/{core_id}/{home_id}/verification",
    response_model=CoreAuditVerificationResponse,
)
def verification(
    core_id: Identity,
    home_id: Identity,
    actor: Admin,
    core: Core,
    checkpoint: Annotated[str | None, Query(max_length=512)] = None,
):
    return core.core_audit.verification(
        actor,
        core_id,
        home_id,
        expected_checkpoint=checkpoint,
    )
