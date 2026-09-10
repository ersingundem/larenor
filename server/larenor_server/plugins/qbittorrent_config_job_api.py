"""Administrator API for durable qBittorrent configuration jobs."""

from typing import Annotated

from fastapi import APIRouter, Depends, Query

from ..admin.models import ObjectId
from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .qbittorrent_config_job_models import (
    CancelQbittorrentConfigurationRequest,
    CreateQbittorrentConfigurationRequest,
    QbittorrentConfigurationCapabilities, QbittorrentConfigurationResponse,
    QbittorrentConfigurationsResponse,
)


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    prefix='/admin/media/qbittorrent-configurations',
    tags=['qBittorrent configuration jobs'],
    responses={status: {'model': ErrorResponse} for status in (400, 401, 403, 404, 409, 413, 503)},
)


@router.get('/capabilities', response_model=QbittorrentConfigurationCapabilities)
def capabilities(core: Core, actor: Admin):
    return core.qbittorrent_configurations.capabilities(actor)


@router.post('', response_model=QbittorrentConfigurationResponse, status_code=201)
def create(body: CreateQbittorrentConfigurationRequest, core: Core, actor: Admin):
    return core.qbittorrent_configurations.create(actor, body)


@router.get('', response_model=QbittorrentConfigurationsResponse)
def list_configurations(core: Core, actor: Admin,
                        before: Annotated[int | None, Query(ge=1, le=2**63 - 1)] = None,
                        limit: Annotated[int, Query(ge=1, le=10)] = 10):
    return core.qbittorrent_configurations.list(actor, before=before, limit=limit)


@router.get('/{identifier}', response_model=QbittorrentConfigurationResponse)
def get(identifier: ObjectId, core: Core, actor: Admin):
    return core.qbittorrent_configurations.get(actor, identifier)


@router.post('/{identifier}/cancel', response_model=QbittorrentConfigurationResponse)
def cancel(identifier: ObjectId, body: CancelQbittorrentConfigurationRequest,
           core: Core, actor: Admin):
    return core.qbittorrent_configurations.cancel(actor, identifier, body)
