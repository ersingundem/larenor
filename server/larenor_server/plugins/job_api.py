from typing import Annotated

from fastapi import APIRouter, Depends, Query

from ..admin.models import ObjectId
from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .job_models import (CancelJobRequest, CreateJobRequest, JobCapabilities, JobEventsResponse,
                         JobResponse, JobsResponse)


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(prefix="/admin/plugins/jobs", tags=["Read-only requirements jobs"], responses={
    status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 409, 413, 503)
})


@router.get("/capabilities", response_model=JobCapabilities)
def capabilities(core: Core, actor: Admin):
    return core.plugin_jobs.capabilities(actor)


@router.post("", response_model=JobResponse, status_code=202)
def create(body: CreateJobRequest, core: Core, actor: Admin):
    return core.plugin_jobs.create(actor, body)


@router.get("", response_model=JobsResponse)
def list_jobs(core: Core, actor: Admin, before: Annotated[int | None, Query(ge=1, le=2**63 - 1)] = None,
              limit: Annotated[int, Query(ge=1, le=100)] = 25):
    return core.plugin_jobs.list(actor, before=before, limit=limit)


@router.get("/{job_id}", response_model=JobResponse)
def get(job_id: ObjectId, core: Core, actor: Admin):
    return core.plugin_jobs.get(actor, job_id)


@router.get("/{job_id}/events", response_model=JobEventsResponse)
def events(job_id: ObjectId, core: Core, actor: Admin, after: Annotated[int, Query(ge=0, le=2**63 - 1)] = 0,
           limit: Annotated[int, Query(ge=1, le=100)] = 25):
    return core.plugin_jobs.events(actor, job_id, after=after, limit=limit)


@router.post("/{job_id}/cancel", response_model=JobResponse)
def cancel(job_id: ObjectId, body: CancelJobRequest, core: Core, actor: Admin):
    return core.plugin_jobs.cancel(actor, job_id, body)
