"""Administrator API for durable Seerr bootstrap jobs."""

from typing import Annotated

from fastapi import APIRouter, Depends, Query

from ..admin.models import ObjectId
from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .seerr_bootstrap_job_models import (
    CreateSeerrBootstrapRequest,
    SeerrBootstrapJobResponse,
    SeerrBootstrapJobsResponse,
)


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    prefix="/admin/media/seerr-bootstraps",
    tags=["Seerr bootstrap jobs"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 503)
    },
)


@router.post("", response_model=SeerrBootstrapJobResponse, status_code=201)
def create(body: CreateSeerrBootstrapRequest, core: Core, actor: Admin):
    return core.seerr_bootstraps.create(actor, body)


@router.get("", response_model=SeerrBootstrapJobsResponse)
def list_bootstraps(
    core: Core,
    actor: Admin,
    before: Annotated[int | None, Query(ge=1, le=2**63 - 1)] = None,
    limit: Annotated[int, Query(ge=1, le=10)] = 10,
):
    return core.seerr_bootstraps.list(actor, before=before, limit=limit)


@router.get("/{identifier}", response_model=SeerrBootstrapJobResponse)
def get(identifier: ObjectId, core: Core, actor: Admin):
    return core.seerr_bootstraps.get(actor, identifier)

