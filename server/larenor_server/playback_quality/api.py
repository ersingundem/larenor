from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    PlaybackInfoAssessmentResponse,
    PlaybackInfoObservationRequest,
    PlaybackInfoObservationResponse,
    PlaybackQualityAdviceRequest,
    PlaybackQualityAdviceResponse,
)


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
ROOT = "/media/playback-quality/{core_id}/{home_id}/advice"
OBSERVE = "/media/playback-quality/{core_id}/{home_id}/observe-item"
ASSESS = "/media/playback-quality/{core_id}/{home_id}/assess-item"
router = APIRouter(
    tags=["Playback quality advice"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 429, 503)
    },
)


@router.post(ROOT, response_model=PlaybackQualityAdviceResponse)
def advise(
    core_id: Identity,
    home_id: Identity,
    body: PlaybackQualityAdviceRequest,
    actor: Ready,
    core: Core,
):
    return core.playback_quality.advise(actor, core_id, home_id, body)


@router.post(OBSERVE, response_model=PlaybackInfoObservationResponse)
def observe_item(
    core_id: Identity,
    home_id: Identity,
    body: PlaybackInfoObservationRequest,
    actor: Ready,
    core: Core,
):
    return core.playback_quality.observe_item(
        actor, core_id, home_id, body)


@router.post(ASSESS, response_model=PlaybackInfoAssessmentResponse)
def assess_item(
    core_id: Identity,
    home_id: Identity,
    body: PlaybackInfoObservationRequest,
    actor: Ready,
    core: Core,
):
    return core.playback_quality.assess_item(
        actor, core_id, home_id, body)
