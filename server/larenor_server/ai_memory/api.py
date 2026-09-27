"""HTTP boundary for visible, time-bounded AI memory."""

from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    CorrectMemory,
    ForgetMemory,
    RememberMemory,
    RestoreAiMemoryBackup,
    SearchMemory,
)


Core = Annotated[object, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    tags=["AI memory"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 503)
    },
)
ROOT = "/ai-memory/{core_id}/{home_id}"


@router.get(ROOT)
def snapshot(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.ai_memory.snapshot(actor, core_id, home_id)


@router.post(ROOT + "/memories", status_code=201)
def remember(
    core_id: Identity,
    home_id: Identity,
    body: RememberMemory,
    actor: Ready,
    core: Core,
):
    return core.ai_memory.remember(actor, core_id, home_id, body)


@router.put(ROOT + "/memories/{memory_id}")
def correct(
    core_id: Identity,
    home_id: Identity,
    memory_id: Identity,
    body: CorrectMemory,
    actor: Ready,
    core: Core,
):
    return core.ai_memory.correct(actor, core_id, home_id, memory_id, body)


@router.post(ROOT + "/memories/{memory_id}/forget")
def forget(
    core_id: Identity,
    home_id: Identity,
    memory_id: Identity,
    body: ForgetMemory,
    actor: Ready,
    core: Core,
):
    return core.ai_memory.forget(actor, core_id, home_id, memory_id, body)


@router.post(ROOT + "/search")
def search(
    core_id: Identity,
    home_id: Identity,
    body: SearchMemory,
    actor: Ready,
    core: Core,
):
    return core.ai_memory.search(actor, core_id, home_id, body)


@router.get(ROOT + "/backup")
def export_backup(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.ai_memory.export_backup(actor, core_id, home_id)


@router.post(ROOT + "/backup/restore")
def restore_backup(
    core_id: Identity,
    home_id: Identity,
    body: RestoreAiMemoryBackup,
    actor: Ready,
    core: Core,
):
    return core.ai_memory.restore_backup(actor, core_id, home_id, body)
