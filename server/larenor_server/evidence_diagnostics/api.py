"""HTTP seams for evidence diagnostics; no endpoint executes a repair."""

from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    CreateDiagnosis,
    CreateHomeAssistantDiagnosis,
    CreateRepairPreview,
)


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(tags=["Evidence diagnostics"], responses={
    status: {"model": ErrorResponse}
    for status in (400, 401, 403, 404, 409, 413, 503)
})
ROOT = "/evidence-diagnostics/{core_id}/{home_id}"


@router.post(ROOT + "/diagnoses", status_code=201)
def diagnose(core_id: Identity, home_id: Identity, body: CreateDiagnosis,
             actor: Ready, core: Core):
    return core.evidence_diagnostics.diagnose(actor, core_id, home_id, body)


@router.post(ROOT + "/home-assistant-history-diagnoses", status_code=201)
def diagnose_home_assistant_history(
    core_id: Identity, home_id: Identity, body: CreateHomeAssistantDiagnosis,
    actor: Admin, core: Core,
):
    return core.evidence_diagnostics.diagnose_home_assistant_history(
        actor, core_id, home_id, body
    )


@router.get(ROOT + "/diagnoses/{diagnosis_id}")
def diagnosis(core_id: Identity, home_id: Identity, diagnosis_id: Identity,
              actor: Ready, core: Core):
    return core.evidence_diagnostics.diagnosis(actor, core_id, home_id, diagnosis_id)


@router.post(ROOT + "/diagnoses/{diagnosis_id}/repair-previews", status_code=201)
def preview_repair(core_id: Identity, home_id: Identity, diagnosis_id: Identity,
                   body: CreateRepairPreview, actor: Admin, core: Core):
    return core.evidence_diagnostics.preview_repair(
        actor, core_id, home_id, diagnosis_id, body
    )
