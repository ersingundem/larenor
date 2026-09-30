"""HTTP boundary for account-scoped habit anomaly reports."""

from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_admin, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    IngestHomeAssistantHistory,
    MarkHabitObservation,
    RecordHabitObservation,
)


Core = Annotated[object, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(tags=["Habit anomalies"], responses={
    status: {"model": ErrorResponse}
    for status in (400, 401, 403, 404, 409, 429, 503)
})
ROOT = "/habit-anomalies/{core_id}/{home_id}"


@router.get(ROOT)
def snapshot(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.habit_anomalies.snapshot(actor, core_id, home_id)


@router.post(ROOT + "/observations", status_code=201)
def record(core_id: Identity, home_id: Identity, body: RecordHabitObservation,
           actor: Ready, core: Core):
    return core.habit_anomalies.record(actor, core_id, home_id, body)


@router.post(ROOT + "/home-assistant-history", status_code=201)
def ingest_home_assistant_history(
    core_id: Identity, home_id: Identity, body: IngestHomeAssistantHistory,
    actor: Admin, core: Core,
):
    return core.habit_anomalies.ingest_home_assistant_history(
        actor, core_id, home_id, body
    )


@router.post(ROOT + "/observations/{observation_id}/feedback")
def mark(core_id: Identity, home_id: Identity, observation_id: Identity,
         body: MarkHabitObservation, actor: Ready, core: Core):
    return core.habit_anomalies.mark(
        actor, core_id, home_id, observation_id, body
    )
