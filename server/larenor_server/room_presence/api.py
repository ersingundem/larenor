from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .management_models import (
    CalibrationPreview,
    CalibrationPreviewCommand,
    CalibrationReceipt,
    PresenceAuthorityRequest,
    PresenceClientAuthority,
    PresenceDevicePage,
    PresenceDeviceView,
    PresenceRouteBinding,
)


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    tags=["Room presence"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 429, 503)
    },
)
ROOT = "/room-presence/{core_id}/{home_id}"


@router.post(ROOT + "/scope", response_model=PresenceClientAuthority)
def scope(
    core_id: Identity,
    home_id: Identity,
    body: PresenceRouteBinding,
    actor: Ready,
    core: Core,
):
    return core.room_presence.scope_authority(actor, core_id, home_id, body)


@router.post(ROOT + "/devices/query", response_model=PresenceDevicePage)
def devices(
    core_id: Identity,
    home_id: Identity,
    body: PresenceAuthorityRequest,
    actor: Ready,
    core: Core,
):
    return core.room_presence.list_devices(actor, core_id, home_id, body.authority)


@router.post(
    ROOT + "/devices/{device_id}/calibration/preview",
    response_model=CalibrationPreview,
)
def preview_calibration(
    core_id: Identity,
    home_id: Identity,
    device_id: Identity,
    body: CalibrationPreviewCommand,
    actor: Ready,
    core: Core,
):
    return core.room_presence.preview(actor, core_id, home_id, device_id, body)


@router.post(
    ROOT + "/calibrations/{request_id}/confirm",
    response_model=CalibrationReceipt,
)
def confirm_calibration(
    core_id: Identity,
    home_id: Identity,
    request_id: Identity,
    body: CalibrationPreview,
    actor: Ready,
    core: Core,
):
    return core.room_presence.confirm(actor, core_id, home_id, request_id, body)


@router.post(ROOT + "/devices/{device_id}/readback", response_model=PresenceDeviceView)
def readback(
    core_id: Identity,
    home_id: Identity,
    device_id: Identity,
    body: PresenceAuthorityRequest,
    actor: Ready,
    core: Core,
):
    return core.room_presence.readback(
        actor, core_id, home_id, device_id, body.authority
    )
