"""Authenticated HTTP boundary for privacy-scoped camera metadata search."""

from typing import Annotated

import hashlib

from fastapi import APIRouter, Depends, Request, Response

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user, require_admin
from ..errors import ApiError
from ..models import ErrorResponse
from .models import (
    CameraEvidenceLink,
    CameraSearchContextResponse,
    CameraSearchFeedbackRequest,
    CameraSearchFeedbackResponse,
    CameraSearchPage,
    CameraSearchRequest,
    Identity,
)


from .runtime import CameraSearchRuntime

def get_camera_search_runtime(request: Request) -> CameraSearchRuntime:
    runtime = getattr(request.app.state, "camera_search_runtime", None)
    if not isinstance(runtime, CameraSearchRuntime):
        raise ApiError("service_unavailable", 503)
    return runtime


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Runtime = Annotated[CameraSearchRuntime, Depends(get_camera_search_runtime)]

router = APIRouter(
    tags=["Camera recording search"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 429, 503)
    },
)


@router.get('/admin/camera-search/{core_id}/{home_id}/sources')
def camera_search_sources(core_id: Identity, home_id: Identity,
        actor: Annotated[Principal, Depends(require_admin)], core: Core,
        runtime: Runtime):
    if (core_id, home_id) != (core.context.coreId, core.context.homeId):
        raise ApiError('not_found', 404)
    if not hasattr(runtime, 'source_state'):
        raise ApiError('service_unavailable', 503)
    return runtime.source_state(actor)


@router.put('/admin/camera-search/{core_id}/{home_id}/sources')
def configure_camera_search_sources(core_id: Identity, home_id: Identity,
        body: dict, actor: Annotated[Principal, Depends(require_admin)], core: Core,
        runtime: Runtime):
    from .frigate import FrigateSearchBinding
    if (core_id, home_id) != (core.context.coreId, core.context.homeId):
        raise ApiError('not_found', 404)
    if not hasattr(runtime, 'configure'):
        raise ApiError('service_unavailable', 503)
    try:
        parsed = FrigateSearchBinding.model_validate(body)
    except (TypeError, ValueError):
        raise ApiError('invalid_request', 400) from None
    core.auth.rate_limit([('camera_search_configuration', actor.id, 30)])
    return runtime.configure(actor, parsed.model_dump(mode='json'))


@router.get(
    "/camera-search/{core_id}/{home_id}/context",
    response_model=CameraSearchContextResponse,
)
def camera_search_context(
    core_id: Identity,
    home_id: Identity,
    actor: Ready,
    core: Core,
    runtime: Runtime,
):
    return runtime.context(core, actor, core_id, home_id)


@router.post(
    "/camera-search/{core_id}/{home_id}/search",
    response_model=CameraSearchPage,
)
def search_camera_metadata(
    core_id: Identity,
    home_id: Identity,
    body: CameraSearchRequest,
    actor: Ready,
    core: Core,
    runtime: Runtime,
):
    return runtime.search(core, actor, core_id, home_id, body)


@router.post(
    "/camera-search/{core_id}/{home_id}/feedback",
    response_model=CameraSearchFeedbackResponse,
)
def report_camera_search_result(
    core_id: Identity,
    home_id: Identity,
    body: CameraSearchFeedbackRequest,
    actor: Ready,
    core: Core,
    runtime: Runtime,
):
    return runtime.feedback(core, actor, core_id, home_id, body)


@router.post('/camera-search/{core_id}/{home_id}/clip')
def read_camera_clip(core_id: Identity, home_id: Identity, body: CameraEvidenceLink,
        actor: Ready, core: Core, runtime: Runtime):
    content = runtime.clip(core, actor, core_id, home_id, body)
    return Response(content, media_type='video/mp4', headers={
        'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
        'X-Larenor-Content-Sha256': hashlib.sha256(content).hexdigest(),
        'X-Larenor-Clip-Id': body.clipId,
    })
