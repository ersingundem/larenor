from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import MediaLanguagePreferenceResponse, PutMediaLanguagePreference


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
ROOT = "/media/language-preferences/{core_id}/{home_id}"
router = APIRouter(
    tags=["Core media language preferences"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 429, 503)
    },
)


@router.get(ROOT, response_model=MediaLanguagePreferenceResponse)
def read(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.media_language_preferences.read(actor, core_id, home_id)


@router.put(ROOT, response_model=MediaLanguagePreferenceResponse)
def put(
    core_id: Identity,
    home_id: Identity,
    body: PutMediaLanguagePreference,
    actor: Ready,
    core: Core,
):
    return core.media_language_preferences.put(actor, core_id, home_id, body)
