from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..errors import ApiError
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .api_models import (
    AcceptEvccBatteryBinding,
    ConfirmEnergyCommand,
    EnergyPrioritySnapshot,
    PreviewEnergyCommand,
)
from .models import InverterCommandPreview, InverterCommandResult

Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
ROOT = "/energy-priorities/{core_id}/{home_id}"
router = APIRouter(
    tags=["Energy priorities"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 429, 503)
    },
)


@router.get(ROOT, response_model=EnergyPrioritySnapshot)
def snapshot(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.energy_priorities.snapshot(actor, core_id, home_id)


@router.post(ROOT + "/previews", status_code=201, response_model=InverterCommandPreview)
def preview(
    core_id: Identity,
    home_id: Identity,
    body: PreviewEnergyCommand,
    actor: Ready,
    core: Core,
):
    return core.energy_priorities.preview(actor, core_id, home_id, body)


@router.post(
    ROOT + "/previews/{request_id}/confirm",
    response_model=InverterCommandResult,
)
def confirm(
    core_id: Identity,
    home_id: Identity,
    request_id: Identity,
    body: ConfirmEnergyCommand,
    actor: Ready,
    core: Core,
):
    return core.energy_priorities.confirm(actor, core_id, home_id, request_id, body)


@router.get(ROOT + "/commands/{request_id}", response_model=InverterCommandResult)
def result(
    core_id: Identity,
    home_id: Identity,
    request_id: Identity,
    actor: Ready,
    core: Core,
):
    return core.energy_priorities.result(actor, core_id, home_id, request_id)


@router.put(ROOT + "/providers/evcc/{service_id}/battery-binding")
def accept_evcc_battery_binding(
    core_id: Identity,
    home_id: Identity,
    service_id: Identity,
    body: AcceptEvccBatteryBinding,
    actor: Admin,
    core: Core,
):
    if (core_id, home_id) != (core.context.coreId, core.context.homeId):
        raise ApiError("not_found", 404)
    store = getattr(core, "evcc_battery_bindings", None)
    if store is None:
        raise ApiError("energy_provider_unavailable", 503)
    revision = store.accept(
        actor,
        service_id=service_id,
        service_revision=body.expectedServiceRevision,
        expected_binding_revision=body.expectedBindingRevision,
        expected_battery_catalog_revision=body.expectedBatteryCatalogRevision,
        backup_reserve_percent=body.backupReservePercent,
        max_charge_power_w=body.maxChargePowerW,
        max_discharge_power_w=body.maxDischargePowerW,
    )
    return {"schemaVersion": 1, "bindingRevision": revision}


@router.get(ROOT + "/providers/evcc/{service_id}/battery-binding")
def evcc_battery_binding_metadata(
    core_id: Identity,
    home_id: Identity,
    service_id: Identity,
    actor: Admin,
    core: Core,
):
    if (core_id, home_id) != (core.context.coreId, core.context.homeId):
        raise ApiError("not_found", 404)
    store = getattr(core, "evcc_battery_bindings", None)
    if store is None:
        raise ApiError("energy_provider_unavailable", 503)
    return {
        "schemaVersion": 1,
        **store.metadata(actor, service_id=service_id),
    }
