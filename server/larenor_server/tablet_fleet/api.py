from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    CompleteTabletCommand,
    IssueTabletCommand,
    PollTabletCommands,
    PublishTabletProfile,
    PreviewKioskProfileRollout,
    KioskProfileRolloutPreview,
    RegisterTablet,
    TabletCommandPage,
    TabletCommandResponse,
    TabletHeartbeat,
    TabletList,
    TabletProfilePublicationResponse,
    TabletResponse,
    UpdateTabletProfile,
)


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
Expected = Annotated[int, Query(ge=1, le=2**63 - 1)]
AuditLimit = Annotated[int, Query(ge=1, le=100)]
router = APIRouter(tags=["Managed tablets"], responses={
    status: {"model": ErrorResponse}
    for status in (400, 401, 403, 404, 409, 413, 429, 503)
})
ROOT = "/tablet-fleet/{core_id}/{home_id}"


@router.get(ROOT + "/audit")
def audit(core_id: Identity, home_id: Identity, actor: Admin, core: Core,
          limit: AuditLimit = 100):
    return core.tablet_fleet.audit(actor, core_id, home_id, limit)


@router.post(ROOT + "/devices", status_code=201, response_model=TabletResponse)
def register(core_id: Identity, home_id: Identity, body: RegisterTablet,
             actor: Ready, core: Core):
    return core.tablet_fleet.register(actor, core_id, home_id, body)


@router.get(ROOT + "/devices", response_model=TabletList)
def devices(core_id: Identity, home_id: Identity, actor: Admin, core: Core):
    return core.tablet_fleet.list(actor, core_id, home_id)


@router.post(ROOT + "/profiles/dry-run", response_model=KioskProfileRolloutPreview)
def preview_profile_rollout(core_id: Identity, home_id: Identity,
                            body: PreviewKioskProfileRollout,
                            actor: Admin, core: Core):
    return core.tablet_fleet.preview_profile_rollout(
        actor, core_id, home_id, body)


@router.post(ROOT + "/devices/{device_id}/heartbeat", response_model=TabletResponse)
def heartbeat(core_id: Identity, home_id: Identity, device_id: Identity,
              body: TabletHeartbeat, actor: Ready, core: Core):
    return core.tablet_fleet.heartbeat(actor, core_id, home_id, device_id, body)


@router.put(ROOT + "/devices/{device_id}/profile", response_model=TabletResponse)
def profile(core_id: Identity, home_id: Identity, device_id: Identity,
            body: UpdateTabletProfile, actor: Admin, core: Core):
    return core.tablet_fleet.update_profile(actor, core_id, home_id, device_id, body)


@router.put(
    ROOT + "/devices/{device_id}/profile-publication",
    response_model=TabletProfilePublicationResponse,
)
def publish_profile(core_id: Identity, home_id: Identity, device_id: Identity,
                    body: PublishTabletProfile, actor: Admin, core: Core):
    return core.tablet_fleet.publish_profile(
        actor, core_id, home_id, device_id, body
    )


@router.get(
    ROOT + "/devices/{device_id}/profile-publication",
    response_model=TabletProfilePublicationResponse,
)
def read_profile(core_id: Identity, home_id: Identity, device_id: Identity,
                 actor: Ready, core: Core):
    return core.tablet_fleet.read_profile(actor, core_id, home_id, device_id)


@router.delete(ROOT + "/devices/{device_id}", status_code=204)
def revoke(core_id: Identity, home_id: Identity, device_id: Identity,
           expectedRevision: Expected, actor: Admin, core: Core):
    core.tablet_fleet.revoke(actor, core_id, home_id, device_id, expectedRevision)
    return Response(status_code=204)


@router.post(ROOT + "/devices/{device_id}/commands", status_code=201,
             response_model=TabletCommandResponse)
def issue(core_id: Identity, home_id: Identity, device_id: Identity,
          body: IssueTabletCommand, actor: Admin, core: Core):
    return core.tablet_fleet.issue(actor, core_id, home_id, device_id, body)


@router.post(ROOT + "/devices/{device_id}/commands/poll", response_model=TabletCommandPage)
def poll(core_id: Identity, home_id: Identity, device_id: Identity,
         body: PollTabletCommands, actor: Ready, core: Core):
    return core.tablet_fleet.poll(actor, core_id, home_id, device_id, body)


@router.post(ROOT + "/devices/{device_id}/commands/{command_id}/complete",
             response_model=TabletCommandResponse)
def complete(core_id: Identity, home_id: Identity, device_id: Identity,
             command_id: Identity, body: CompleteTabletCommand,
             actor: Ready, core: Core):
    return core.tablet_fleet.complete(
        actor, core_id, home_id, device_id, command_id, body)
