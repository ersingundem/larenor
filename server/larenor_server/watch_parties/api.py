"""HTTP boundary for revision-bound household watch parties."""

from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    CommandWatchPartyRequest,
    CreateWatchPartyRequest,
    CreateWatchPartyResponse,
    JoinWatchPartyRequest,
    LeaveWatchPartyRequest,
    LeaveWatchPartyResponse,
    ReportWatchPartyRequest,
    TransferWatchPartyLeaderRequest,
    WatchPartySnapshotResponse,
)

Core = Annotated[object, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    prefix="/media/watch-parties", tags=["Watch parties"],
    responses={status: {"model": ErrorResponse}
               for status in (400, 401, 403, 404, 409, 429, 503)},
)


@router.post("", response_model=CreateWatchPartyResponse, status_code=201)
def create(body: CreateWatchPartyRequest, core: Core, actor: Ready):
    return core.watch_parties.create(actor, body)


@router.post("/{room_id}/join", response_model=WatchPartySnapshotResponse)
def join(room_id: Identity, body: JoinWatchPartyRequest,
         core: Core, actor: Ready):
    return core.watch_parties.join(actor, room_id, body)


@router.get("/{room_id}", response_model=WatchPartySnapshotResponse)
def snapshot(room_id: Identity, core: Core, actor: Ready):
    return core.watch_parties.snapshot(actor, room_id)


@router.post("/{room_id}/reports", response_model=WatchPartySnapshotResponse)
def report(room_id: Identity, body: ReportWatchPartyRequest,
           core: Core, actor: Ready):
    return core.watch_parties.report(actor, room_id, body)


@router.post("/{room_id}/commands", response_model=WatchPartySnapshotResponse)
def command(room_id: Identity, body: CommandWatchPartyRequest,
            core: Core, actor: Ready):
    return core.watch_parties.command(actor, room_id, body)


@router.post("/{room_id}/leader", response_model=WatchPartySnapshotResponse)
def transfer(room_id: Identity, body: TransferWatchPartyLeaderRequest,
             core: Core, actor: Ready):
    return core.watch_parties.transfer(actor, room_id, body)


@router.post("/{room_id}/leave", response_model=LeaveWatchPartyResponse)
def leave(room_id: Identity, body: LeaveWatchPartyRequest,
          core: Core, actor: Ready):
    return core.watch_parties.leave(actor, room_id, body)
