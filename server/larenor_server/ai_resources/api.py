from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import ChangeAiJob, EnqueueAiJob, ReportMediaActivity, UpdateAiResourcePolicy


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(tags=["AI resources"], responses={
    status: {"model": ErrorResponse}
    for status in (400, 401, 403, 404, 409, 413, 429, 503)
})
ROOT = "/ai-resources/{core_id}/{home_id}"


@router.get(ROOT)
def snapshot(core_id: Identity, home_id: Identity, actor: Admin, core: Core):
    return core.ai_resources.snapshot(actor, core_id, home_id)


@router.put(ROOT + "/policy")
def update_policy(core_id: Identity, home_id: Identity, body: UpdateAiResourcePolicy,
                  actor: Admin, core: Core):
    return core.ai_resources.update_policy(actor, core_id, home_id, body)


@router.post(ROOT + "/jobs")
def enqueue(core_id: Identity, home_id: Identity, body: EnqueueAiJob,
            actor: Ready, core: Core):
    return core.ai_resources.enqueue(actor, core_id, home_id, body)


@router.post(ROOT + "/jobs/{job_id}/cancel")
def cancel(core_id: Identity, home_id: Identity, job_id: Identity, body: ChangeAiJob,
           actor: Ready, core: Core):
    return core.ai_resources.cancel(actor, core_id, home_id, job_id, body)


@router.post(ROOT + "/jobs/{job_id}/complete")
def complete(core_id: Identity, home_id: Identity, job_id: Identity, body: ChangeAiJob,
             actor: Ready, core: Core):
    return core.ai_resources.complete(actor, core_id, home_id, job_id, body)


@router.put(ROOT + "/media-activity")
def media_activity(core_id: Identity, home_id: Identity, body: ReportMediaActivity,
                   actor: Ready, core: Core):
    return core.ai_resources.media_activity(actor, core_id, home_id, body)

