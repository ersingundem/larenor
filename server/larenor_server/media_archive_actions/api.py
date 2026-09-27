"""Admin-only HTTP surface for explicit F30 archive actions."""

from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .models import (
    ArchiveActionJobRequest,
    ArchiveActionJobResponse,
    ArchiveActionPolicyResponse,
    ArchiveActionPreviewResponse,
    ConfirmArchiveActionRequest,
    PreviewArchiveActionRequest,
    PreviewArchiveCleanupRequest,
    SnapshotActionRequest,
    SnapshotActionResponse,
    UpdateArchiveActionPolicyRequest,
)


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    prefix="/admin/media/archive-actions",
    tags=["Media archive actions"],
    responses={status: {"model": ErrorResponse}
               for status in (400, 401, 403, 404, 409, 429, 503)},
)


@router.post("/snapshot", response_model=SnapshotActionResponse)
def snapshot(body: SnapshotActionRequest, core: Core, actor: Admin):
    return core.media_archive_actions.snapshot(actor, body)


@router.post("/policy", response_model=ArchiveActionPolicyResponse)
def update_policy(
        body: UpdateArchiveActionPolicyRequest, core: Core, actor: Admin):
    return core.media_archive_actions.update_policy(actor, body)


@router.post("/preview", response_model=ArchiveActionPreviewResponse)
def preview(body: PreviewArchiveActionRequest, core: Core, actor: Admin):
    return core.media_archive_actions.preview(actor, body)


@router.post("/confirm", response_model=ArchiveActionJobResponse)
def confirm(body: ConfirmArchiveActionRequest, core: Core, actor: Admin):
    return core.media_archive_actions.confirm(actor, body)


@router.post("/cleanup/preview", response_model=ArchiveActionPreviewResponse)
def preview_cleanup(
        body: PreviewArchiveCleanupRequest, core: Core, actor: Admin):
    return core.media_archive_actions.preview_cleanup(actor, body)


@router.post("/cleanup/confirm", response_model=ArchiveActionJobResponse)
def confirm_cleanup(
        body: ConfirmArchiveActionRequest, core: Core, actor: Admin):
    return core.media_archive_actions.confirm(actor, body)


@router.post("/jobs/read", response_model=ArchiveActionJobResponse)
def read_job(body: ArchiveActionJobRequest, core: Core, actor: Admin):
    return core.media_archive_actions.read_job(actor, body)


@router.post("/jobs/cancel", response_model=ArchiveActionJobResponse)
def cancel_job(body: ArchiveActionJobRequest, core: Core, actor: Admin):
    return core.media_archive_actions.cancel(actor, body)


@router.post("/jobs/reconcile", response_model=ArchiveActionJobResponse)
def reconcile_job(body: ArchiveActionJobRequest, core: Core, actor: Admin):
    return core.media_archive_actions.reconcile(actor, body)
