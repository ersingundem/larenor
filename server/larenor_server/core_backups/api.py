from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .models import (
    BackupPlanResponse,
    RestoreValidationRequest,
    RestoreValidationResponse,
)

Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    prefix="/admin/backups",
    tags=["Core backup contract"],
    responses={
        status: {"model": ErrorResponse} for status in (400, 401, 403, 409, 413, 503)
    },
)


@router.get("/plan", response_model=BackupPlanResponse)
def plan(core: Core, actor: Admin):
    return core.core_backups.plan(actor)


@router.post("/restore/validate", response_model=RestoreValidationResponse)
def validate_restore(body: RestoreValidationRequest, core: Core, _actor: Admin):
    return core.core_backups.validate_restore(body.manifest)
