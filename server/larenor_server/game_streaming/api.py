from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (AuthorizeGameStreamIntent, CompleteGameStreamIntent,
                     OpenGameStreamSession, RegisterGameStreamHost)

Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(tags=["Game streaming"], responses={
    status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 409, 413, 429, 503)
})
ROOT = "/game-streaming/{core_id}/{home_id}"


@router.post(ROOT + "/hosts", status_code=201)
def register(core_id: Identity, home_id: Identity, body: RegisterGameStreamHost,
             actor: Admin, core: Core):
    return core.game_streaming.register(actor, core_id, home_id, body)


@router.get(ROOT + "/hosts")
def hosts(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.game_streaming.hosts(actor, core_id, home_id)


@router.post(ROOT + "/hosts/{host_id}/sessions", status_code=201)
def open_session(core_id: Identity, home_id: Identity, host_id: Identity,
                 body: OpenGameStreamSession, actor: Ready, core: Core):
    return core.game_streaming.open(actor, core_id, home_id, host_id, body)


@router.post(ROOT + "/sessions/{session_id}/commands", status_code=201)
def authorize(core_id: Identity, home_id: Identity, session_id: Identity,
              body: AuthorizeGameStreamIntent, actor: Ready, core: Core):
    return core.game_streaming.authorize(actor, core_id, home_id, session_id, body)


@router.post(ROOT + "/sessions/{session_id}/commands/{command_id}/complete")
def complete(core_id: Identity, home_id: Identity, session_id: Identity,
             command_id: Identity, body: CompleteGameStreamIntent,
             actor: Ready, core: Core):
    return core.game_streaming.complete(
        actor, core_id, home_id, session_id, command_id, body)
