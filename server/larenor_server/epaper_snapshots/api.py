"""Authenticated F58 management and bounded bridge delivery routes."""

from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Response
from pydantic import Field

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..home_resources.models import FrozenModel, Identity
from ..models import ErrorResponse
from .models import (
    EpaperDataSnapshot,
    EpaperDeliveryAck,
    EpaperDevice,
    EpaperLayout,
    EpaperPolicy,
)

Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
Revision = Annotated[int, Field(ge=1, le=2**63 - 1)]


class AuthorityRequest(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    accountId: Identity
    sessionFamilyId: Identity
    homeRevision: Revision
    accountRevision: Revision
    sessionRevision: Revision

    def authority_fields(self):
        return {
            name: getattr(self, name)
            for name in (
                "coreId", "homeId", "accountId", "sessionFamilyId",
                "homeRevision", "accountRevision", "sessionRevision",
            )
        }


class MapDeviceRequest(AuthorityRequest):
    expectedMappingRevision: Annotated[int, Field(ge=0, le=2**63 - 1)]
    name: str = Field(min_length=1, max_length=80, pattern=r"^[^\x00-\x1f\x7f]+$")
    ttlSeconds: Annotated[int, Field(ge=60, le=86_400)]
    device: EpaperDevice
    layout: EpaperLayout
    data: EpaperDataSnapshot
    policy: EpaperPolicy


class PreviewRequest(AuthorityRequest):
    expectedDeviceRevision: str = Field(min_length=1, max_length=20, pattern=r"^[1-9][0-9]*$")
    action: Literal["refresh"]


class PollRequest(AuthorityRequest):
    requestId: Identity
    expectedDeviceRevision: Revision


class AcknowledgeRequest(AuthorityRequest):
    ack: EpaperDeliveryAck


router = APIRouter(
    tags=["E-paper mini home screens"],
    responses={status: {"model": ErrorResponse}
               for status in (400, 401, 403, 404, 409, 413, 429, 503)},
)
ROOT = "/epaper/{core_id}/{home_id}"
ADMIN = "/admin/epaper/{core_id}/{home_id}"


@router.get(ROOT + "/authority")
def authority(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.epaper.authority(actor, core_id, home_id)


@router.post(ROOT + "/devices")
def devices(core_id: Identity, home_id: Identity, body: AuthorityRequest,
            actor: Ready, core: Core):
    return core.epaper.list_devices(actor, core_id, home_id, body)


@router.post(ROOT + "/devices/{device_id}")
def device(core_id: Identity, home_id: Identity, device_id: Identity,
           body: AuthorityRequest, actor: Ready, core: Core):
    return core.epaper.readback(actor, core_id, home_id, device_id, body)


@router.put(ADMIN + "/devices/{device_id}")
def map_device(core_id: Identity, home_id: Identity, device_id: Identity,
               body: MapDeviceRequest, actor: Admin, core: Core):
    if body.device.deviceId != device_id:
        from ..errors import ApiError
        raise ApiError("revision_conflict", 409)
    return core.epaper.map_device(actor, core_id, home_id, body)


@router.post(ADMIN + "/devices/{device_id}/previews", status_code=201)
def preview(core_id: Identity, home_id: Identity, device_id: Identity,
            body: PreviewRequest, actor: Admin, core: Core):
    return core.epaper.preview(actor, core_id, home_id, device_id, body)


@router.delete(ADMIN + "/previews/{request_id}", status_code=204)
def cancel(core_id: Identity, home_id: Identity, request_id: Identity,
           body: AuthorityRequest, actor: Admin, core: Core):
    core.epaper.cancel_preview(actor, core_id, home_id, request_id, body)
    return Response(status_code=204)


@router.post(ADMIN + "/previews/{request_id}/confirm")
def confirm(core_id: Identity, home_id: Identity, request_id: Identity,
            body: AuthorityRequest, actor: Admin, core: Core):
    return core.epaper.confirm(actor, core_id, home_id, request_id, body)


@router.post(ROOT + "/devices/{device_id}/poll")
def poll(core_id: Identity, home_id: Identity, device_id: Identity,
         body: PollRequest, actor: Ready, core: Core):
    return core.epaper.poll(actor, core_id, home_id, device_id, body)


@router.post(ROOT + "/devices/{device_id}/acknowledgements")
def acknowledge(core_id: Identity, home_id: Identity, device_id: Identity,
                body: AcknowledgeRequest, actor: Ready, core: Core):
    return core.epaper.acknowledge(actor, core_id, home_id, device_id, body)
