from typing import Annotated

from fastapi import APIRouter, Depends, Header, Request
from starlette.responses import StreamingResponse

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..errors import ApiError
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import TransferRequest
from .service import WIRE_TYPE


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(tags=["Bounded resource transfer"], responses={
    status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 408, 409, 413, 429, 503)})
PATH = "/home-resources/{core_id}/{home_id}/{record_id}/blob"


@router.post(PATH)
async def download(core_id: Identity, home_id: Identity, record_id: Identity,
                   body: TransferRequest, request: Request, actor: Ready, core: Core,
                   range_header: Annotated[str | None, Header(alias="Range")] = None,
                   if_range: Annotated[str | None, Header(alias="If-Range")] = None):
    if range_header is not None or if_range is not None:
        raise ApiError("invalid_request", 400)
    disconnected = False
    opened = core.bounded_transfers.open(
        actor, core_id, home_id, record_id,
        expected_user_revision=body.expectedUserRevision,
        expected_revision=body.expectedRevision,
        expected_acl_revision=body.expectedAclRevision,
        expected_service_revision=body.expectedServiceRevision,
        deadline_ms=body.deadlineMs,
        cancelled=lambda: disconnected,
    )

    async def stream():
        nonlocal disconnected
        try:
            while True:
                disconnected = await request.is_disconnected()
                try:
                    frame = next(opened.frames)
                except StopIteration:
                    return
                yield frame
        finally:
            disconnected = True
            opened.close()

    metadata = opened.metadata
    return StreamingResponse(stream(), media_type=WIRE_TYPE, headers={
        "Content-Length": str(metadata.framed_length),
        "X-Larenor-Trace-Id": metadata.trace_id,
        "X-Larenor-Blob-Content-Length": str(metadata.content_length),
        "X-Larenor-Blob-Sha256": metadata.sha256,
        "X-Larenor-Blob-Content-Type": metadata.content_type,
        "X-Larenor-Service-Revision": str(metadata.service_revision),
        "Cache-Control": "no-store",
        "Accept-Ranges": "none",
    })
