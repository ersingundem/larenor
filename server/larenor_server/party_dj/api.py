"""HTTP boundary for revision-bound Music Assistant party DJ rooms."""

from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    CreatePartyDjRoomRequest, CreatePartyDjRoomResponse,
    DecidePartyDjProposalRequest, HeartbeatPartyDjRequest,
    DismissPartyDjProposalRequest, DismissPartyDjSkipRequest,
    JoinPartyDjRoomRequest, LeavePartyDjRequest, LeavePartyDjResponse,
    PartyDjRoomResponse, ProposePartyDjTrackRequest,
    VotePartyDjProposalRequest, VotePartyDjSkipRequest,
)

Core = Annotated[object, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    prefix="/media/party-dj", tags=["Party DJ"],
    responses={status: {"model": ErrorResponse}
               for status in (400, 401, 403, 404, 409, 429, 503)},
)


@router.post("/rooms", response_model=CreatePartyDjRoomResponse,
             status_code=201)
def create(body: CreatePartyDjRoomRequest, core: Core, actor: Ready):
    return core.party_dj.create(actor, body)


@router.post("/rooms/{room_id}/join", response_model=PartyDjRoomResponse)
def join(room_id: Identity, body: JoinPartyDjRoomRequest,
         core: Core, actor: Ready):
    return core.party_dj.join(actor, room_id, body)


@router.get("/rooms/{room_id}", response_model=PartyDjRoomResponse)
def snapshot(room_id: Identity, core: Core, actor: Ready):
    return core.party_dj.snapshot(actor, room_id)


@router.post("/rooms/{room_id}/heartbeat",
             response_model=PartyDjRoomResponse)
def heartbeat(room_id: Identity, body: HeartbeatPartyDjRequest,
              core: Core, actor: Ready):
    return core.party_dj.heartbeat(actor, room_id, body)


@router.post("/rooms/{room_id}/leave", response_model=LeavePartyDjResponse)
def leave(room_id: Identity, body: LeavePartyDjRequest,
          core: Core, actor: Ready):
    return core.party_dj.leave(actor, room_id, body)


@router.post("/rooms/{room_id}/proposals",
             response_model=PartyDjRoomResponse, status_code=201)
def propose(room_id: Identity, body: ProposePartyDjTrackRequest,
            core: Core, actor: Ready):
    return core.party_dj.propose(actor, room_id, body)


@router.post("/rooms/{room_id}/proposals/{proposal_id}/votes",
             response_model=PartyDjRoomResponse)
def vote(room_id: Identity, proposal_id: Identity,
         body: VotePartyDjProposalRequest, core: Core, actor: Ready):
    return core.party_dj.vote(actor, room_id, proposal_id, body)


@router.post("/rooms/{room_id}/proposals/{proposal_id}/decision",
             response_model=PartyDjRoomResponse)
def decide(room_id: Identity, proposal_id: Identity,
           body: DecidePartyDjProposalRequest, core: Core, actor: Ready):
    return core.party_dj.decide(actor, room_id, proposal_id, body)


@router.post("/rooms/{room_id}/proposals/{proposal_id}/dismiss",
             response_model=PartyDjRoomResponse)
def dismiss_proposal(room_id: Identity, proposal_id: Identity,
                     body: DismissPartyDjProposalRequest,
                     core: Core, actor: Ready):
    return core.party_dj.dismiss_proposal(actor, room_id, proposal_id, body)


@router.post("/rooms/{room_id}/skip-votes",
             response_model=PartyDjRoomResponse)
def skip(room_id: Identity, body: VotePartyDjSkipRequest,
         core: Core, actor: Ready):
    return core.party_dj.skip(actor, room_id, body)


@router.post("/rooms/{room_id}/skip-votes/dismiss",
             response_model=PartyDjRoomResponse)
def dismiss_skip(room_id: Identity, body: DismissPartyDjSkipRequest,
                 core: Core, actor: Ready):
    return core.party_dj.dismiss_skip(actor, room_id, body)
