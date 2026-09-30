"""Unified, secret-free Music Assistant provider/catalog/queue API."""

from typing import Annotated

from fastapi import APIRouter, Depends

from ..admin.models import ObjectId
from ..auth import Principal
from ..dependencies import get_core, require_ready_user
from ..models import ErrorResponse
from .music_playback_models import (
    MusicCatalogSearchResponse, MusicLongformCatalogResponse,
    MusicManagerStateResponse,
    MusicPlaybackCommandRequest, MusicPlaybackReceiptResponse,
    ReadMusicLongformRequest, RefreshMusicPlaybackRequest,
    SearchMusicCatalogRequest,
)
from .music_retained_status_models import MusicRetainedStatusResponse


Core = Annotated[object, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    prefix='/admin/media/music-assistant/manager',
    tags=['Managed Music Assistant'],
    responses={status: {'model': ErrorResponse}
               for status in (400, 401, 403, 404, 409, 503)})


@router.get('/available', response_model=MusicRetainedStatusResponse)
def available(core: Core, actor: Ready):
    return core.music_retained_status.read(actor, member_view=True)


@router.post('/refresh', response_model=MusicManagerStateResponse)
def refresh_manager(body: RefreshMusicPlaybackRequest, core: Core,
                    actor: Ready):
    core.music_playback.refresh(actor, body)
    return core.music_playback.manager(actor, body.installationId)


@router.get('/{installation_id}', response_model=MusicManagerStateResponse)
def manager(installation_id: ObjectId, core: Core, actor: Ready):
    return core.music_playback.manager(actor, installation_id)


@router.post('/catalog/search', response_model=MusicCatalogSearchResponse)
def search_catalog(body: SearchMusicCatalogRequest, core: Core, actor: Ready):
    return core.music_playback.search(actor, body)


@router.post('/catalog/in-progress', response_model=MusicLongformCatalogResponse)
def read_longform(body: ReadMusicLongformRequest, core: Core, actor: Ready):
    return core.music_playback.longform(actor, body)


@router.post('/commands', response_model=MusicPlaybackReceiptResponse,
             status_code=201)
def manager_command(body: MusicPlaybackCommandRequest, core: Core,
                    actor: Ready):
    return core.music_playback.command(actor, body)
