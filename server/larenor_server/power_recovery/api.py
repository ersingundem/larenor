from typing import Annotated

from fastapi import APIRouter, Depends, Header

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .models import (
    ConfigurePowerRecoveryRequest,
    Identity,
    PowerRecoveryPolicyResponse,
    PowerRecoveryStatus,
    PowerRecoveryRun,
    ReconcilePowerRecoveryRequest,
    RetryPowerRecoveryRequest,
    UpsEventReceipt,
    UpsPowerEvent,
)


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    prefix="/admin/power-recovery",
    tags=["Power recovery"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 409, 429, 503)
    },
)


@router.get("/policy", response_model=PowerRecoveryPolicyResponse)
def get_policy(core: Core, actor: Admin):
    return core.power_recovery.policy(actor)


@router.put("/policy", response_model=PowerRecoveryPolicyResponse)
def configure_policy(body: ConfigurePowerRecoveryRequest, core: Core, actor: Admin):
    return core.power_recovery.configure(actor, body)


@router.get("/status", response_model=PowerRecoveryStatus)
def status(core: Core, actor: Admin):
    return core.power_recovery.status(actor)


@router.post("/events", response_model=UpsEventReceipt)
def ingest_event(
    body: UpsPowerEvent,
    core: Core,
    x_larenor_ups_token: Annotated[str | None, Header()] = None,
):
    return core.power_recovery.ingest(x_larenor_ups_token, body)


@router.post("/runs/{run_id}/retry", response_model=PowerRecoveryRun)
def retry_run(
    run_id: Identity,
    body: RetryPowerRecoveryRequest,
    core: Core,
    actor: Admin,
):
    return core.power_recovery.retry(actor, run_id, body)


@router.post(
    "/runs/{run_id}/steps/{step_id}/reconcile",
    response_model=PowerRecoveryRun,
)
def reconcile_step(
    run_id: Identity,
    step_id: Identity,
    body: ReconcilePowerRecoveryRequest,
    core: Core,
    actor: Admin,
):
    return core.power_recovery.reconcile_step(actor, run_id, step_id, body)
