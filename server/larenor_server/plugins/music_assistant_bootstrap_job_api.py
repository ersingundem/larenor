"""Administrator API for durable Music Assistant bootstrap jobs."""

from typing import Annotated

from fastapi import APIRouter, Depends, Query

from ..admin.models import ObjectId
from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .music_assistant_bootstrap_job_models import (
    CreateMusicAssistantBootstrapRequest,
    MusicAssistantBootstrapJobResponse,
    MusicAssistantBootstrapJobsResponse,
)

Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    prefix="/admin/media/music-assistant-bootstraps",
    tags=["Music Assistant bootstrap jobs"],
    responses={status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 409, 503)},
)


@router.post("", response_model=MusicAssistantBootstrapJobResponse, status_code=201)
def create(body: CreateMusicAssistantBootstrapRequest, core: Core, actor: Admin):
    return core.music_assistant_bootstraps.create(actor, body)


@router.get("", response_model=MusicAssistantBootstrapJobsResponse)
def list_bootstraps(
    core: Core,
    actor: Admin,
    before: Annotated[int | None, Query(ge=1, le=2**63 - 1)] = None,
    limit: Annotated[int, Query(ge=1, le=10)] = 10,
):
    return core.music_assistant_bootstraps.list(actor, before=before, limit=limit)


@router.get("/{identifier}", response_model=MusicAssistantBootstrapJobResponse)
def get(identifier: ObjectId, core: Core, actor: Admin):
    return core.music_assistant_bootstraps.get(actor, identifier)
