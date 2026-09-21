"""Authenticated HTTP boundary for the shared family board."""

from typing import Annotated, Literal

from fastapi import APIRouter, Depends
from pydantic import Field

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import FrozenModel, Identity
from ..models import ErrorResponse
from .models import (
    BoardAuthority,
    BoardCommand,
    BoardDelta,
    BoardElement,
    BoardReceipt,
    BoardSnapshot,
)


Revision = Annotated[int, Field(ge=1, le=2**63 - 1)]
Sequence = Annotated[int, Field(ge=0, le=2**63 - 1)]
Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]


class AuthorityExpectations(FrozenModel):
    expectedHomeRevision: Revision
    expectedAccountRevision: Revision
    expectedMemberRevision: Revision
    expectedSessionFamilyId: Identity


class DeltaRequest(AuthorityExpectations):
    schemaVersion: Literal[1]
    afterSequence: Sequence
    limit: Annotated[int, Field(ge=1, le=100)] = 100


class CommandRequest(AuthorityExpectations):
    schemaVersion: Literal[1]
    requestId: Identity
    expectedBoardRevision: Sequence
    action: Literal["append", "update", "delete"]
    element: BoardElement | None = None
    elementId: Identity | None = None

    def command(self):
        return BoardCommand.model_validate(
            self.model_dump(
                include={
                    "schemaVersion", "requestId", "expectedBoardRevision",
                    "action", "element", "elementId",
                }
            )
        )


router = APIRouter(
    tags=["Family board"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 429, 503)
    },
)
ROOT = "/family-boards/{core_id}/{home_id}"


@router.get(ROOT + "/authority", response_model=BoardAuthority)
def authority(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.family_board.authority(actor, core_id, home_id)


@router.get(ROOT + "/{board_id}", response_model=BoardSnapshot)
def snapshot(core_id: Identity, home_id: Identity, board_id: Identity,
             actor: Ready, core: Core):
    return core.family_board.snapshot(actor, core_id, home_id, board_id)


@router.post(ROOT + "/{board_id}/delta", response_model=BoardDelta)
def delta(core_id: Identity, home_id: Identity, board_id: Identity,
          body: DeltaRequest, actor: Ready, core: Core):
    return core.family_board.delta(actor, core_id, home_id, board_id, body)


@router.post(ROOT + "/{board_id}/commands", response_model=BoardReceipt)
def command(core_id: Identity, home_id: Identity, board_id: Identity,
            body: CommandRequest, actor: Ready, core: Core):
    return core.family_board.apply(actor, core_id, home_id, board_id, body)
