from typing import Annotated

from fastapi import APIRouter, Depends, Path

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..errors import ApiError
from ..evcc import AcceptedEnergyWindows, AcceptedWindowSlot
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .http_models import (
    AcceptEnergyWindows,
    AuthorizeCurrentControl,
    ConfirmCharge,
    PreviewCharge,
)

Core = Annotated[CoreServices, Depends(get_core)]
User = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
ROOT = "/ev-charging/{core_id}/{home_id}"
router = APIRouter(
    tags=["EV charging"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 503)
    },
)


@router.get(ROOT + "/capability")
def capability(core_id: Identity, home_id: Identity, actor: User, core: Core):
    return core.ev_charging.capability(actor, core_id, home_id)


@router.post(ROOT + "/chargers/{charger_id}/previews", status_code=201)
def preview(
    core_id: Identity,
    home_id: Identity,
    charger_id: Identity,
    body: PreviewCharge,
    actor: User,
    core: Core,
):
    return core.ev_charging.preview(actor, core_id, home_id, charger_id, body)


@router.post(ROOT + "/chargers/{charger_id}/commands", status_code=201)
def confirm(
    core_id: Identity,
    home_id: Identity,
    charger_id: Identity,
    body: ConfirmCharge,
    actor: User,
    core: Core,
):
    return core.ev_charging.confirm(actor, core_id, home_id, charger_id, body)


@router.get(ROOT + "/chargers/{charger_id}/commands/{command_id}")
def command_result(
    core_id: Identity,
    home_id: Identity,
    charger_id: Identity,
    command_id: Identity,
    actor: User,
    core: Core,
):
    return core.ev_charging.result(
        actor, core_id, home_id, charger_id, command_id
    )


@router.put(ROOT + "/providers/evcc/{service_id}/energy-windows")
def accept_energy_windows(
    core_id: Identity,
    home_id: Identity,
    service_id: Identity,
    body: AcceptEnergyWindows,
    actor: Admin,
    core: Core,
):
    if (core_id, home_id) != (core.context.coreId, core.context.homeId):
        raise ApiError("not_found", 404)
    revision = core.evcc_energy_windows.accept(
        actor,
        service_id=service_id,
        service_revision=body.expectedServiceRevision,
        expected_accepted_revision=body.expectedAcceptedRevision,
        windows=AcceptedEnergyWindows(
            tariff_revision=body.tariffRevision,
            solar_revision=body.solarRevision,
            power_budget_revision=body.powerBudgetRevision,
            override_revision=body.overrideRevision,
            observed_at=body.observedAtMs / 1000,
            expires_at=body.expiresAtMs / 1000,
            slots=tuple(
                AcceptedWindowSlot(
                    item.startAtMs / 1000,
                    item.endAtMs / 1000,
                    item.tariffMicrosPerKwh,
                    item.solarSurplusW,
                    item.homeBudgetW,
                )
                for item in body.slots
            ),
        ),
    )
    return {"schemaVersion": 1, "acceptedRevision": revision}


@router.get(ROOT + "/providers/evcc/{service_id}/energy-windows")
def accepted_energy_window_metadata(
    core_id: Identity,
    home_id: Identity,
    service_id: Identity,
    actor: Admin,
    core: Core,
):
    if (core_id, home_id) != (core.context.coreId, core.context.homeId):
        raise ApiError("not_found", 404)
    return {
        "schemaVersion": 1,
        **core.evcc_energy_windows.metadata(actor, service_id=service_id),
    }


@router.put(
    ROOT + "/providers/evcc/{service_id}/loadpoints/{loadpoint_index}/current-control"
)
def authorize_current_control(
    core_id: Identity,
    home_id: Identity,
    service_id: Identity,
    loadpoint_index: Annotated[int, Path(ge=1, le=16)],
    body: AuthorizeCurrentControl,
    actor: Admin,
    core: Core,
):
    if (core_id, home_id) != (core.context.coreId, core.context.homeId):
        raise ApiError("not_found", 404)
    if core.evcc_current_control is None:
        raise ApiError("ev_charge_provider_unavailable", 503)
    revision = core.evcc_current_control.authorize(
        actor,
        service_id=service_id,
        service_revision=body.expectedServiceRevision,
        loadpoint_index=loadpoint_index,
        expected_authority_revision=body.expectedAuthorityRevision,
        enabled=body.enabled,
    )
    return {"schemaVersion": 1, "authorityRevision": revision}


@router.get(
    ROOT + "/providers/evcc/{service_id}/loadpoints/{loadpoint_index}/current-control"
)
def current_control_metadata(
    core_id: Identity,
    home_id: Identity,
    service_id: Identity,
    loadpoint_index: Annotated[int, Path(ge=1, le=16)],
    actor: Admin,
    core: Core,
):
    if (core_id, home_id) != (core.context.coreId, core.context.homeId):
        raise ApiError("not_found", 404)
    if core.evcc_current_control is None:
        raise ApiError("ev_charge_provider_unavailable", 503)
    return {
        "schemaVersion": 1,
        **core.evcc_current_control.metadata(
            actor, service_id=service_id, loadpoint_index=loadpoint_index
        ),
    }
