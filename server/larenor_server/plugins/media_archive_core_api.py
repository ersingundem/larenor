from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_admin, require_ready_user
from ..models import ErrorResponse
from .media_archive_core_models import (
    MediaArchiveAuthorityRequest,
    MediaArchiveAuthorityResponse,
    MediaArchiveReadRequest,
    MediaArchiveReadResponse,
    MediaCatalogBrowseRequest,
    MediaCatalogSearchRequest,
    MediaCatalogSearchResponse,
    MediaCatalogTargetResponse,
)


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
Ready = Annotated[Principal, Depends(require_ready_user)]
router = APIRouter(
    prefix='/admin/media/archive-health',
    tags=['Media archive health'],
    responses={status: {'model': ErrorResponse}
               for status in (400, 401, 403, 404, 409, 503)},
)
catalog_router = APIRouter(
    prefix='/media/catalog',
    tags=['Media catalog'],
    responses={status: {'model': ErrorResponse}
               for status in (400, 401, 403, 404, 409, 503)},
)


@router.post('/authority', response_model=MediaArchiveAuthorityResponse)
def authority(body: MediaArchiveAuthorityRequest, core: Core, actor: Admin):
    return core.media_archive_health.authority(actor, body)


@router.post('/read', response_model=MediaArchiveReadResponse)
def read(body: MediaArchiveReadRequest, core: Core, actor: Admin):
    return core.media_archive_health.read(actor, body)


@router.post('/catalog/search', response_model=MediaCatalogSearchResponse)
def search(body: MediaCatalogSearchRequest, core: Core, actor: Admin):
    return core.media_archive_health.search(actor, body)


@catalog_router.get('/target', response_model=MediaCatalogTargetResponse)
def catalog_target(core: Core, actor: Ready):
    return core.media_archive_health.member_target(actor)


@catalog_router.post('/search', response_model=MediaCatalogSearchResponse)
def catalog_search(body: MediaCatalogSearchRequest, core: Core, actor: Ready):
    return core.media_archive_health.member_search(actor, body)


@catalog_router.post('/browse', response_model=MediaCatalogSearchResponse)
def catalog_browse(body: MediaCatalogBrowseRequest, core: Core, actor: Ready):
    return core.media_archive_health.member_browse(actor, body)
