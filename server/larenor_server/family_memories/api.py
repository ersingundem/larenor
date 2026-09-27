"""Authenticated F38 family memory routes."""

from typing import Annotated

from fastapi import APIRouter, Depends, Response

from ..admin.models import ObjectId
from ..auth import Principal
from ..dependencies import get_core, require_ready_user
from ..models import ErrorResponse
from .contracts import (
    CreateMemoryAlbumRequest, DeleteMemoryAlbumRequest, MemoryAlbumResponse,
    MemorySearchRequest, MemorySearchResponse, MemorySnapshotRequest,
    MemorySnapshotResponse, ReconcileMemoryAlbumRequest,
    ReplaceMemorySelectionsRequest,
    UpdateMemoryAlbumRequest,
)


Core = Annotated[object, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    prefix="/family-memories", tags=["Family memories"],
    responses={status: {"model": ErrorResponse}
               for status in (400, 401, 403, 404, 409, 413, 429, 503)},
)


@router.post("/snapshot", response_model=MemorySnapshotResponse)
def snapshot(body: MemorySnapshotRequest, core: Core, actor: Ready):
    return core.family_memories.snapshot(actor, body)


@router.post("/search", response_model=MemorySearchResponse)
def search(body: MemorySearchRequest, core: Core, actor: Ready):
    return core.family_memories.search(actor, body)


@router.post("/albums", response_model=MemoryAlbumResponse, status_code=201)
def create(body: CreateMemoryAlbumRequest, core: Core, actor: Ready):
    return core.family_memories.create(actor, body)


@router.put("/albums/{album_id}", response_model=MemoryAlbumResponse)
def update(album_id: ObjectId, body: UpdateMemoryAlbumRequest,
           core: Core, actor: Ready):
    return core.family_memories.update(actor, album_id, body)


@router.put("/albums/{album_id}/assets", response_model=MemoryAlbumResponse)
def replace(album_id: ObjectId, body: ReplaceMemorySelectionsRequest,
            core: Core, actor: Ready):
    return core.family_memories.replace(actor, album_id, body)


@router.post("/albums/{album_id}/reconcile", response_model=MemoryAlbumResponse)
def reconcile(album_id: ObjectId, body: ReconcileMemoryAlbumRequest,
              core: Core, actor: Ready):
    return core.family_memories.reconcile(actor, album_id, body)


@router.delete("/albums/{album_id}", status_code=204)
def delete(album_id: ObjectId, body: DeleteMemoryAlbumRequest,
           core: Core, actor: Ready):
    core.family_memories.delete(actor, album_id, body)
    return Response(status_code=204)
