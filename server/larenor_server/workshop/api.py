from typing import Annotated

from fastapi import APIRouter, Depends, Query

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    ConfirmIntent,
    IntentList,
    IntentResponse,
    PreviewIntent,
    PreviewResponse,
    PrinterList,
    PrinterResponse,
    RegisterPrinter,
    UpdatePrinterState,
)


Core = Annotated[CoreServices, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
Limit = Annotated[int, Query(ge=1, le=100)]
ROOT = "/workshop/{core_id}/{home_id}"
router = APIRouter(tags=["Workshop"], responses={
    status: {"model": ErrorResponse}
    for status in (400, 401, 403, 404, 409, 413, 429, 503)
})


@router.post(ROOT + "/printers", status_code=201, response_model=PrinterResponse)
def register(core_id: Identity, home_id: Identity, body: RegisterPrinter,
             actor: Admin, core: Core):
    return core.workshop.register(actor, core_id, home_id, body)


@router.get(ROOT + "/printers", response_model=PrinterList)
def printers(core_id: Identity, home_id: Identity, actor: Admin, core: Core):
    return core.workshop.list(actor, core_id, home_id)


@router.put(ROOT + "/printers/{printer_id}/state", response_model=PrinterResponse)
def update_state(core_id: Identity, home_id: Identity, printer_id: Identity,
                 body: UpdatePrinterState, actor: Admin, core: Core):
    return core.workshop.update_state(
        actor, core_id, home_id, printer_id, body
    )


@router.post(ROOT + "/printers/{printer_id}/previews", status_code=201,
             response_model=PreviewResponse)
def preview(core_id: Identity, home_id: Identity, printer_id: Identity,
            body: PreviewIntent, actor: Admin, core: Core):
    return core.workshop.preview(actor, core_id, home_id, printer_id, body)


@router.post(ROOT + "/printers/{printer_id}/previews/{preview_id}/confirm",
             status_code=201, response_model=IntentResponse)
def confirm(core_id: Identity, home_id: Identity, printer_id: Identity,
            preview_id: Identity, body: ConfirmIntent, actor: Admin, core: Core):
    return core.workshop.confirm(
        actor, core_id, home_id, printer_id, preview_id, body
    )


@router.get(ROOT + "/printers/{printer_id}/intents", response_model=IntentList)
def intents(core_id: Identity, home_id: Identity, printer_id: Identity,
            actor: Admin, core: Core, limit: Limit = 100):
    return core.workshop.intents(actor, core_id, home_id, printer_id, limit)
