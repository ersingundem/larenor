import asyncio
from threading import Event
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    CreateWorkflowRequest,
    WorkflowDecisionRequest,
    WorkflowListResponse,
    WorkflowResponse,
    WorkflowResumeRequest,
)


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Limit = Annotated[int, Query(ge=1, le=50)]
ROOT = "/home-workflows/{core_id}/{home_id}"
router = APIRouter(
    tags=["Durable home workflows"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 408, 409, 413, 429, 503)
    },
)


async def observe(request, operation):
    cancelled = Event()

    async def monitor():
        while not cancelled.is_set():
            if await request.is_disconnected():
                cancelled.set()
                return
            await asyncio.sleep(0.05)

    watcher = asyncio.create_task(monitor())
    try:
        return await asyncio.to_thread(operation, cancelled.is_set)
    finally:
        cancelled.set()
        watcher.cancel()
        try:
            await watcher
        except asyncio.CancelledError:
            pass


@router.post(ROOT, status_code=201, response_model=WorkflowResponse)
def create(core_id: Identity, home_id: Identity, body: CreateWorkflowRequest,
           actor: Ready, core: Core):
    return core.home_workflows.create(actor, core_id, home_id, body)


@router.get(ROOT, response_model=WorkflowListResponse)
def list_workflows(core_id: Identity, home_id: Identity, actor: Ready, core: Core,
                   before: Identity | None = None, limit: Limit = 25):
    return core.home_workflows.list(
        actor, core_id, home_id, before=before, limit=limit
    )


@router.get(ROOT + "/{workflow_id}", response_model=WorkflowResponse)
def get(core_id: Identity, home_id: Identity, workflow_id: Identity,
        actor: Ready, core: Core):
    return core.home_workflows.get(actor, core_id, home_id, workflow_id)


@router.post(ROOT + "/{workflow_id}/decisions", response_model=WorkflowResponse)
async def decide(core_id: Identity, home_id: Identity, workflow_id: Identity,
                 body: WorkflowDecisionRequest, request: Request,
                 actor: Ready, core: Core):
    return await observe(
        request,
        lambda cancelled: core.home_workflows.decide(
            actor, core_id, home_id, workflow_id, body, cancelled=cancelled
        ),
    )


@router.post(ROOT + "/{workflow_id}/resume", response_model=WorkflowResponse)
def resume(core_id: Identity, home_id: Identity, workflow_id: Identity,
           body: WorkflowResumeRequest, actor: Ready, core: Core):
    return core.home_workflows.resume(actor, core_id, home_id, workflow_id, body)
