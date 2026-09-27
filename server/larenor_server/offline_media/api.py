"""Offline media manifest API."""

from typing import Annotated
from fastapi import APIRouter, Depends, Response

from ..admin.models import ObjectId
from ..auth import Principal
from ..dependencies import get_core, require_ready_user
from ..models import ErrorResponse
from .models import (CreateOfflineMediaRequest, OfflineMediaManifestResponse,
                     ReadOfflineMediaChunkRequest,
                     RevokeOfflineMediaRequest,
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
