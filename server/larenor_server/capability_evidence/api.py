from typing import Annotated

from fastapi import APIRouter, Depends, Query
from fastapi.responses import JSONResponse

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import EvidenceList, EvidenceResponse, PutEvidence

Core = Annotated[CoreServices, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
Limit = Annotated[int, Query(ge=1, le=50)]
router = APIRouter(
    tags=["Kiosk capability evidence"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 422, 429, 503)
    },
)
ROOT = "/capability-evidence/{core_id}/{home_id}/records"


@router.get(ROOT, response_model=EvidenceList)
def list_records(
    core_id: Identity,
    home_id: Identity,
    actor: Admin,
    core: Core,
    after: Identity | None = None,
    limit: Limit = 20,
):
    return core.capability_evidence.list(actor, core_id, home_id, after, limit)


@router.put(ROOT + "/{evidence_id}", response_model=EvidenceResponse)
def put_record(
    core_id: Identity,
    home_id: Identity,
    evidence_id: Identity,
    body: PutEvidence,
    actor: Admin,
    core: Core,
):
    value, status = core.capability_evidence.put(
        actor, core_id, home_id, evidence_id, body
    )
    return JSONResponse(
        {"record": value["record"].model_dump(mode="json")}, status_code=status
    )
