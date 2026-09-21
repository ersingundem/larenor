from typing import Annotated

from fastapi import APIRouter, Depends, Response

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .models import (
    BackupExportRequest,
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


@router.post(
    "/export",
    response_class=Response,
    responses={
        200: {
            "description": "Encrypted Larenor Core backup",
            "content": {
                "application/vnd.larenor.core-backup": {
                    "schema": {"type": "string", "format": "binary"}
                }
            },
        }
    },
)
def export(body: BackupExportRequest, core: Core, actor: Admin):
    return Response(
        core.core_backups.export(actor, body.passphrase),
        media_type="application/vnd.larenor.core-backup",
        headers={
            "Content-Disposition": (
                'attachment; filename="larenor-core-backup.larenor-core"'
            ),
            "X-Content-Type-Options": "nosniff",
        },
    )
