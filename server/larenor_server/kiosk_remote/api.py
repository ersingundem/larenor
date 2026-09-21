from typing import Annotated

from fastapi import APIRouter, Depends, Header, Query, Response

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin
from ..home_resources.models import Identity, Revision
from ..models import ErrorResponse
from .models import CreatePairing, MqttAck, MqttCommand


Core = Annotated[CoreServices, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
PairingToken = Annotated[str, Header(alias="X-Larenor-Pairing-Token", min_length=43, max_length=43)]
Expected = Annotated[int, Query(ge=1, le=2**63 - 1)]
ROOT = "/admin/paired-remote/{core_id}/{home_id}"
router = APIRouter(tags=["Paired kiosk remote"], responses={
    status: {"model": ErrorResponse}
    for status in (400, 401, 403, 404, 409, 413, 422, 429, 503)
})


@router.post(ROOT + "/pairings", status_code=201)
def create_pairing(core_id: Identity, home_id: Identity, body: CreatePairing,
                   actor: Admin, core: Core):
    return core.kiosk_remote.create(actor, core_id, home_id, body)


@router.get(ROOT + "/pairings")
def list_pairings(core_id: Identity, home_id: Identity, actor: Admin, core: Core):
    return core.kiosk_remote.list(actor, core_id, home_id)


@router.delete(ROOT + "/pairings/{pairing_id}", status_code=204)
def revoke_pairing(core_id: Identity, home_id: Identity, pairing_id: Identity,
                   expectedRevision: Expected, actor: Admin, core: Core):
    core.kiosk_remote.revoke(actor, core_id, home_id, pairing_id, expectedRevision)
    return Response(status_code=204)


@router.get(ROOT + "/pairings/{pairing_id}/mqtt/discovery")
def discovery(core_id: Identity, home_id: Identity, pairing_id: Identity,
              token: PairingToken, core: Core):
    return core.kiosk_remote.discovery(core_id, home_id, pairing_id, token)


@router.post(ROOT + "/pairings/{pairing_id}/mqtt/commands")
def command(core_id: Identity, home_id: Identity, pairing_id: Identity,
            body: MqttCommand, token: PairingToken, response: Response, core: Core):
    result, created = core.kiosk_remote.submit(core_id, home_id, pairing_id, token, body)
    response.status_code = 201 if created else 200
    return result


@router.post(ROOT + "/pairings/{pairing_id}/mqtt/commands/{command_id}/ack")
def acknowledge(core_id: Identity, home_id: Identity, pairing_id: Identity,
                command_id: Identity, body: MqttAck, token: PairingToken,
                core: Core):
    return core.kiosk_remote.complete(
        core_id, home_id, pairing_id, command_id, token, body
    )
