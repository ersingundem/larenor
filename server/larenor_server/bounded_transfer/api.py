import asyncio
import hashlib
import re
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Request, Response
from starlette.responses import StreamingResponse

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..errors import ApiError
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (ProductBlobResponse, ProductBlobUploadResponse,
                     TransferEventHistoryResponse, TransferHistoryResponse,
                     TransferReceiptResponse, TransferRequest)
from .service import WIRE_TYPE


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(tags=["Bounded resource transfer"], responses={
    status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 408, 409, 413, 429, 503)})
PATH = "/home-resources/{core_id}/{home_id}/{record_id}/blob"
_DIGEST = re.compile(r"^[0-9a-f]{64}$")
_CONTENT_TYPE = re.compile(r"^[A-Za-z0-9!#$&^_.+\-/;= ]{1,128}$")


def _closed_read(request: Request, *, history: bool) -> int:
    if len(request.headers.getlist("authorization")) != 1:
        raise ApiError("invalid_request", 400)
    pairs = list(request.query_params.multi_items())
    if not history:
        if pairs:
            raise ApiError("invalid_request", 400)
        return 50
    if not pairs:
        return 50
    if len(pairs) != 1 or pairs[0][0] != "limit":
        raise ApiError("invalid_request", 400)
    raw = pairs[0][1]
    if not raw.isascii() or not raw.isdecimal() or raw.startswith("0"):
        raise ApiError("invalid_request", 400)
    limit = int(raw)
    if not 1 <= limit <= 50 or str(limit) != raw:
        raise ApiError("invalid_request", 400)
    return limit


def _event_read(request: Request):
    if len(request.headers.getlist("authorization")) != 1:
        raise ApiError("invalid_request", 400)
    values = {}
    for key, raw in request.query_params.multi_items():
        if key not in {"after", "limit"} or key in values:
            raise ApiError("invalid_request", 400)
        if not raw.isascii() or not raw.isdecimal() or raw.startswith("0"):
            raise ApiError("invalid_request", 400)
        value = int(raw)
        maximum = 2048 if key == "after" else 50
        if not 1 <= value <= maximum or str(value) != raw:
            raise ApiError("invalid_request", 400)
        values[key] = value
    return values.get("after"), values.get("limit", 50)


def _one_header(request: Request, name: str) -> str:
    values = request.headers.getlist(name)
    if len(values) != 1:
        raise ApiError("invalid_request", 400)
    return values[0]


def _integer_header(request: Request, name: str, *, zero=False) -> int:
    raw = _one_header(request, name)
    if not raw.isascii() or not raw.isdecimal() or (raw.startswith("0") and raw != "0"):
        raise ApiError("invalid_request", 400)
    value = int(raw)
    minimum = 0 if zero else 1
    if not minimum <= value <= 2**63 - 1 or str(value) != raw:
        raise ApiError("invalid_request", 400)
    return value


def _upload_values(request: Request, request_id: str):
    if request.query_params or _one_header(request, "x-larenor-upload-request-id") != request_id:
        raise ApiError("invalid_request", 400)
    length = _integer_header(request, "content-length")
    if length > 256 * 1024:
        raise ApiError("payload_too_large", 413)
    digest = _one_header(request, "x-larenor-content-sha256")
    content_type = _one_header(request, "content-type")
    if (
        _DIGEST.fullmatch(digest) is None
        or _CONTENT_TYPE.fullmatch(content_type) is None
        or "\r" in content_type
        or "\n" in content_type
    ):
        raise ApiError("invalid_request", 400)
    return {
        "expectedUserRevision": _integer_header(
            request, "x-larenor-expected-user-revision"
        ),
        "expectedRevision": _integer_header(
            request, "x-larenor-expected-resource-revision"
        ),
        "expectedAclRevision": _integer_header(
            request, "x-larenor-expected-acl-revision"
        ),
        "expectedServiceRevision": _integer_header(
            request, "x-larenor-expected-service-revision", zero=True
        ),
        "contentLength": length,
        "sha256": digest,
        "contentType": content_type,
    }


async def _bounded_body(request: Request, expected_length: int) -> bytes:
    content = bytearray()
    try:
        async with asyncio.timeout(15):
            async for chunk in request.stream():
                if await request.is_disconnected():
                    raise ApiError("transfer_cancelled", 408)
                content.extend(chunk)
                if len(content) > 256 * 1024:
                    raise ApiError("payload_too_large", 413)
    except TimeoutError:
        raise ApiError("request_timeout", 408) from None
    if len(content) != expected_length:
        raise ApiError("invalid_request", 400)
    return bytes(content)


@router.get(PATH + "/transfers/events", response_model=TransferEventHistoryResponse)
def event_history(core_id: Identity, home_id: Identity, record_id: Identity,
                  request: Request, actor: Ready, core: Core):
    after, limit = _event_read(request)
    return core.bounded_transfers.events(
        actor, core_id, home_id, record_id, after=after, limit=limit)


@router.get(PATH + "/transfers/{request_id}", response_model=TransferReceiptResponse)
def receipt(core_id: Identity, home_id: Identity, record_id: Identity,
            request_id: Identity, request: Request, actor: Ready, core: Core):
    _closed_read(request, history=False)
    return core.bounded_transfers.receipt(
        actor, core_id, home_id, record_id, request_id)


@router.get(PATH + "/transfers", response_model=TransferHistoryResponse)
def history(core_id: Identity, home_id: Identity, record_id: Identity,
            request: Request, actor: Ready, core: Core):
    limit = _closed_read(request, history=True)
    return core.bounded_transfers.history(
        actor, core_id, home_id, record_id, limit)


@router.get(PATH + "/descriptor", response_model=ProductBlobResponse)
def product_descriptor(core_id: Identity, home_id: Identity, record_id: Identity,
                       request: Request, actor: Ready, core: Core):
    _closed_read(request, history=False)
    return core.product_blobs.descriptor(actor, core_id, home_id, record_id)


@router.put(PATH + "/uploads/{request_id}", response_model=ProductBlobUploadResponse,
            status_code=201)
async def upload_product_blob(core_id: Identity, home_id: Identity,
                              record_id: Identity, request_id: Identity,
                              request: Request, response: Response,
                              actor: Ready, core: Core):
    values = _upload_values(request, request_id)
    core.home_resources.authorize(
        actor, core_id, home_id, record_id, "write",
        expected_user_revision=values["expectedUserRevision"],
        expected_revision=values["expectedRevision"],
        expected_acl_revision=values["expectedAclRevision"],
    )
    envelope = core.product_blobs.envelope_hash(
        actor.id, core_id, home_id, record_id, values
    )
    replay = core.product_blobs.replay(
        actor, core_id, home_id, record_id, request_id, envelope
    )
    if replay is not None:
        response.status_code = 200
        return replay
    content = await _bounded_body(request, values["contentLength"])
    if not hashlib.sha256(content).hexdigest() == values["sha256"]:
        raise ApiError("invalid_request", 400)
    result, created = core.product_blobs.put(
        actor, core_id, home_id, record_id, request_id, values, content
    )
    response.status_code = 201 if created else 200
    return result


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
        request_id=body.requestId,
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
