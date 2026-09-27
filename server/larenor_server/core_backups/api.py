from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .models import (
    BackupExportRequest,
    BackupPlanResponse,
    RestoreValidationRequest,
    RestoreValidationResponse,
)
from .drill_models import (
    CancelRecoveryDrillRequest,
    CreateRecoveryDrillRequest,
    ObjectId,
    RecoveryDrillResponse,
    RecoveryDrillsResponse,
    RecoveryDrillScheduleResponse,
    UpdateRecoveryDrillScheduleRequest,
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
    publication = core.core_backups.publish(actor, body.passphrase)
    return Response(
        publication.payload,
        media_type="application/vnd.larenor.core-backup",
        headers={
            "Content-Disposition": (
                'attachment; filename="larenor-core-backup.larenor-core"'
            ),
            "X-Content-Type-Options": "nosniff",
            "X-Larenor-Capture-Generation": publication.capture_generation,
        },
    )


@router.post("/drills", response_model=RecoveryDrillResponse, status_code=201)
def create_drill(body: CreateRecoveryDrillRequest, core: Core, actor: Admin):
    return core.core_backups.drills.create(actor, body)


@router.get("/drills", response_model=RecoveryDrillsResponse)
def list_drills(
    core: Core,
    actor: Admin,
    before: Annotated[int | None, Query(ge=1, le=2**63 - 1)] = None,
    limit: Annotated[int, Query(ge=1, le=20)] = 20,
):
    return core.core_backups.drills.list(actor, before=before, limit=limit)


@router.get("/drills/{drill_id}", response_model=RecoveryDrillResponse)
def get_drill(drill_id: ObjectId, core: Core, actor: Admin):
    return core.core_backups.drills.get(actor, drill_id)


@router.post("/drills/{drill_id}/cancel", response_model=RecoveryDrillResponse)
def cancel_drill(
    drill_id: ObjectId,
    body: CancelRecoveryDrillRequest,
    core: Core,
    actor: Admin,
):
    return core.core_backups.drills.cancel(actor, drill_id, body)


@router.get("/drill-schedule", response_model=RecoveryDrillScheduleResponse)
def get_drill_schedule(core: Core, actor: Admin):
    return core.core_backups.drills.get_schedule(actor)


@router.put("/drill-schedule", response_model=RecoveryDrillScheduleResponse)
def update_drill_schedule(
    body: UpdateRecoveryDrillScheduleRequest,
    core: Core,
    actor: Admin,
):
    return core.core_backups.drills.update_schedule(actor, body)
