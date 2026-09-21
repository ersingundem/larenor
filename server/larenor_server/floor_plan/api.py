from typing import Annotated

from fastapi import APIRouter, Depends, Query

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .api_models import (
    ExportResponse,
    HistoryResponse,
    LayoutModel,
    LayoutResponse,
    ReceiptModel,
    ReceiptResponse,
    ReplaceLayoutRequest,
)


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
Limit = Annotated[int, Query(ge=1, le=1024)]
router = APIRouter(tags=["Interactive floor plan"], responses={
    status: {"model": ErrorResponse}
    for status in (400, 401, 403, 404, 409, 413, 429, 503)
})
ROOT = "/floor-plan/{core_id}/{home_id}"


@router.put(ROOT, response_model=ReceiptResponse)
def replace(core_id: Identity, home_id: Identity, body: ReplaceLayoutRequest,
            actor: Admin, core: Core):
    receipt = core.floor_plan.replace(actor, core_id, home_id, body)
    return {"receipt": ReceiptModel(
        requestId=receipt.request_id,
        revision=receipt.revision,
        status=receipt.status,
    )}


@router.get(ROOT, response_model=LayoutResponse)
def read(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    stored = core.floor_plan.read(actor, core_id, home_id)
    return {
        "layoutRevision": stored.revision,
        "layout": LayoutModel.from_domain(stored.layout),
    }


@router.get(ROOT + "/export", response_model=ExportResponse)
def export(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    result = core.floor_plan.export(actor, core_id, home_id)
    return {**result, "layout": LayoutModel.from_domain(result["layout"])}


@router.get(ROOT + "/history", response_model=HistoryResponse)
def history(core_id: Identity, home_id: Identity, actor: Ready, core: Core,
            limit: Limit = 100):
    return {"entries": list(core.floor_plan.history(actor, core_id, home_id, limit))}
