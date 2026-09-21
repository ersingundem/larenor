from typing import Annotated

from fastapi import APIRouter, Depends, Query

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    ConfirmWarrantyCommand,
    CreateHomeDocumentCommand,
    DocumentCommandResult,
    DocumentPage,
    WarrantyReminderPage,
)

Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    tags=["Home documents"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 429, 503)
    },
)
ROOT = "/home-documents/{core_id}/{home_id}"


@router.get(ROOT + "/documents", response_model=DocumentPage)
def search_documents(
    core_id: Identity,
    home_id: Identity,
    actor: Ready,
    core: Core,
    query: str = Query(default="", max_length=120),
    limit: int = Query(default=50, ge=1, le=50),
):
    return core.home_documents.search(actor, core_id, home_id, query, limit=limit)


@router.get(ROOT + "/reminders", response_model=WarrantyReminderPage)
def warranty_reminders(
    core_id: Identity,
    home_id: Identity,
    actor: Ready,
    core: Core,
    today: str = Query(min_length=10, max_length=10),
    limit: int = Query(default=100, ge=1, le=100),
):
    return core.home_documents.reminders(actor, core_id, home_id, today, limit=limit)


@router.post(ROOT + "/documents", response_model=DocumentCommandResult, status_code=201)
def create_document(
    core_id: Identity,
    home_id: Identity,
    body: CreateHomeDocumentCommand,
    actor: Ready,
    core: Core,
):
    return core.home_documents.create(actor, core_id, home_id, body)


@router.post(
    ROOT + "/documents/{document_id}/warranty",
    response_model=DocumentCommandResult,
)
def confirm_warranty(
    core_id: Identity,
    home_id: Identity,
    document_id: Identity,
    body: ConfirmWarrantyCommand,
    actor: Ready,
    core: Core,
):
    if body.documentId != document_id:
        from ..errors import ApiError

        raise ApiError("invalid_request")
    return core.home_documents.confirm_warranty(actor, core_id, home_id, body)
