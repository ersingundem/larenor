"""Offline media manifest API."""

from typing import Annotated
import asyncio

from fastapi import APIRouter, Depends, Header, Response
from fastapi.responses import StreamingResponse

from ..admin.models import ObjectId
from ..auth import Principal
from ..dependencies import get_core, require_ready_user
from ..models import ErrorResponse
from .models import (CreateOfflineMediaRequest, OfflineMediaManifestResponse,
                     CreateOnlinePlaybackLeaseRequest,
                     OnlinePlaybackLeaseResponse,
                     ReadOfflineMediaChunkRequest,
                     RevokeOfflineMediaRequest,
                     UpdateOnlinePlaybackLeaseRequest,
                     UpdateOfflineMediaProgressRequest)

Core = Annotated[object, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    prefix="/media/offline", tags=["Offline media"],
    responses={status: {"model": ErrorResponse}
               for status in (400, 401, 403, 404, 409, 429, 503)},
)


@router.post("/grants", response_model=OfflineMediaManifestResponse,
             status_code=201)
def create(body: CreateOfflineMediaRequest, core: Core, actor: Ready):
    return core.offline_media.create(actor, body)


@router.get("/grants/{grant_id}", response_model=OfflineMediaManifestResponse)
def get(grant_id: ObjectId, core: Core, actor: Ready):
    return core.offline_media.get(actor, grant_id)


@router.post("/grants/{grant_id}/chunk")
def chunk(grant_id: ObjectId, body: ReadOfflineMediaChunkRequest,
          core: Core, actor: Ready):
    content, content_type, digest = core.offline_media.chunk(
        actor, grant_id, body)
    return Response(content=content, media_type=content_type, headers={
        "Content-Length": str(len(content)),
        "X-Larenor-Content-Sha256": digest,
        "X-Larenor-Chunk-Offset": str(body.offset),
        "Cache-Control": "no-store",
        "Accept-Ranges": "none",
    })


@router.post("/grants/{grant_id}/progress",
             response_model=OfflineMediaManifestResponse)
def progress(grant_id: ObjectId, body: UpdateOfflineMediaProgressRequest,
             core: Core, actor: Ready):
    return core.offline_media.progress(actor, grant_id, body)


@router.post("/grants/{grant_id}/revoke",
             response_model=OfflineMediaManifestResponse)
def revoke(grant_id: ObjectId, body: RevokeOfflineMediaRequest,
           core: Core, actor: Ready):
    return core.offline_media.revoke(actor, grant_id, body)


@router.post("/playback-leases", response_model=OnlinePlaybackLeaseResponse,
             status_code=201)
def create_playback_lease(body: CreateOnlinePlaybackLeaseRequest,
                          core: Core, actor: Ready):
    return core.offline_media.create_playback_lease(actor, body)


@router.post("/playback-leases/{lease_id}/renew",
             response_model=OnlinePlaybackLeaseResponse)
def renew_playback_lease(lease_id: ObjectId,
                         body: UpdateOnlinePlaybackLeaseRequest,
                         core: Core, actor: Ready):
    return core.offline_media.renew_playback_lease(actor, lease_id, body)


@router.post("/playback-leases/{lease_id}/retire",
             response_model=OnlinePlaybackLeaseResponse)
def retire_playback_lease(lease_id: ObjectId,
                          body: UpdateOnlinePlaybackLeaseRequest,
                          core: Core, actor: Ready):
    return core.offline_media.retire_playback_lease(actor, lease_id, body)


def _content_headers(lease, start, end, status):
    headers = {
        "Accept-Ranges": "bytes", "Cache-Control": "no-store",
        "Content-Length": str(end - start + 1),
        "X-Content-Type-Options": "nosniff",
    }
    if status == 206:
        headers["Content-Range"] = (
            f"bytes {start}-{end}/{lease['content_length']}")
    return headers


def _content(core, actor, lease_id, range_header, *, head):
    lease = core.offline_media.playback_content(actor, lease_id)
    selected = core.offline_media.playback_range(
        lease["content_length"], range_header)
    if selected is None:
        return Response(status_code=416, headers={
            "Accept-Ranges": "bytes",
            "Content-Range": f"bytes */{lease['content_length']}",
            "Cache-Control": "no-store",
        })
    start, end, status = selected
    headers = _content_headers(lease, start, end, status)
    if head:
        return Response(status_code=status, media_type="application/octet-stream",
                        headers=headers)

    async def body():
        offset = start
        while offset <= end:
            requested = min(32 * 1024, end - offset + 1)
            content = await asyncio.to_thread(
                core.offline_media.playback_chunk,
                actor, lease_id, offset, requested)
            if not content:
                return
            offset += len(content)
            yield content

    return StreamingResponse(
        body(), status_code=status, media_type="application/octet-stream",
        headers=headers)


@router.get("/playback-leases/{lease_id}/content")
def playback_content(lease_id: ObjectId, core: Core, actor: Ready,
                     range_header: str | None = Header(default=None,
                                                       alias="Range")):
    return _content(core, actor, lease_id, range_header, head=False)


@router.head("/playback-leases/{lease_id}/content")
def playback_content_head(lease_id: ObjectId, core: Core, actor: Ready,
                          range_header: str | None = Header(default=None,
                                                            alias="Range")):
    return _content(core, actor, lease_id, range_header, head=True)
