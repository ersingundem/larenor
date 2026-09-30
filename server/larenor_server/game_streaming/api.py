from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (AuthorizeGameStreamIntent, CatalogObservationIntentRequest,
                     CompleteCatalogObservationIntent, CompleteGameStreamIntent,
                     CompleteGameStreamRevocation, CompletePairingIntent,
                     OpenGameStreamSession, PairingIntentRequest,
                     RetireGameStreamSession, RevokeGameStreamHost)

Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(tags=["Game streaming"], responses={
    status: {"model": ErrorResponse}
    for status in (400, 401, 403, 404, 409, 413, 429, 503)
})
ROOT = "/game-streaming/{core_id}/{home_id}"


@router.post(ROOT + "/pairings", status_code=201)
def create_pairing(core_id: Identity, home_id: Identity, body: PairingIntentRequest,
                   actor: Admin, core: Core):
    return core.game_streaming.create_pairing(actor, core_id, home_id, body)


@router.post(ROOT + "/pairings/{pairing_id}/complete")
def complete_pairing(core_id: Identity, home_id: Identity, pairing_id: Identity,
                     body: CompletePairingIntent, actor: Admin, core: Core):
    return core.game_streaming.complete_pairing(
        actor, core_id, home_id, pairing_id, body)


@router.get(ROOT + "/hosts")
def hosts(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.game_streaming.hosts(actor, core_id, home_id)


@router.get(ROOT + "/hosts/{host_id}/apps")
def apps(core_id: Identity, home_id: Identity, host_id: Identity,
         actor: Ready, core: Core):
    return core.game_streaming.apps(actor, core_id, home_id, host_id)


@router.post(ROOT + "/hosts/{host_id}/catalog-observations", status_code=201)
def create_catalog_observation(core_id: Identity, home_id: Identity,
                               host_id: Identity,
                               body: CatalogObservationIntentRequest,
                               actor: Ready, core: Core):
    return core.game_streaming.create_catalog_observation(
        actor, core_id, home_id, host_id, body)


@router.post(
    ROOT + "/hosts/{host_id}/catalog-observations/{observation_id}/complete")
def complete_catalog_observation(core_id: Identity, home_id: Identity,
                                 host_id: Identity, observation_id: Identity,
                                 body: CompleteCatalogObservationIntent,
                                 actor: Ready, core: Core):
    return core.game_streaming.complete_catalog_observation(
        actor, core_id, home_id, host_id, observation_id, body)


@router.post(ROOT + "/hosts/{host_id}/apps/{app_id}/sessions", status_code=201)
def open_session(core_id: Identity, home_id: Identity, host_id: Identity,
                 app_id: Identity, body: OpenGameStreamSession,
                 actor: Ready, core: Core):
    return core.game_streaming.open(
        actor, core_id, home_id, host_id, app_id, body)


@router.get(ROOT + "/sessions/{session_id}")
def session(core_id: Identity, home_id: Identity, session_id: Identity,
            actor: Ready, core: Core):
    return core.game_streaming.session(actor, core_id, home_id, session_id)


@router.post(ROOT + "/sessions/{session_id}/retire")
def retire(core_id: Identity, home_id: Identity, session_id: Identity,
           body: RetireGameStreamSession, actor: Ready, core: Core):
    return core.game_streaming.retire(
        actor, core_id, home_id, session_id, body)


@router.post(ROOT + "/sessions/{session_id}/commands", status_code=201)
def authorize(core_id: Identity, home_id: Identity, session_id: Identity,
              body: AuthorizeGameStreamIntent, actor: Ready, core: Core):
    return core.game_streaming.authorize(
        actor, core_id, home_id, session_id, body)


@router.get(ROOT + "/sessions/{session_id}/commands/{command_id}")
def command(core_id: Identity, home_id: Identity, session_id: Identity,
            command_id: Identity, actor: Ready, core: Core):
    return core.game_streaming.command(
        actor, core_id, home_id, session_id, command_id)


@router.post(ROOT + "/sessions/{session_id}/commands/{command_id}/complete")
def complete(core_id: Identity, home_id: Identity, session_id: Identity,
             command_id: Identity, body: CompleteGameStreamIntent,
             actor: Ready, core: Core):
    return core.game_streaming.complete(
        actor, core_id, home_id, session_id, command_id, body)


@router.post(ROOT + "/hosts/{host_id}/revoke", status_code=201)
def revoke(core_id: Identity, home_id: Identity, host_id: Identity,
           body: RevokeGameStreamHost, actor: Admin, core: Core):
    return core.game_streaming.revoke(actor, core_id, home_id, host_id, body)


@router.post(ROOT + "/hosts/{host_id}/revocations/{revocation_id}/complete")
def complete_revocation(core_id: Identity, home_id: Identity, host_id: Identity,
                        revocation_id: Identity,
                        body: CompleteGameStreamRevocation,
                        actor: Admin, core: Core):
    return core.game_streaming.complete_revocation(
        actor, core_id, home_id, host_id, revocation_id, body)
