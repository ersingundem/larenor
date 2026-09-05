from typing import Annotated

from fastapi import APIRouter, Depends

from ..admin.models import ObjectId
from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .api_models import PluginCatalogResponse, PluginPreviewRequest, PluginPreviewResponse


Core = Annotated[CoreServices, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(prefix="/admin/plugins", tags=["Plugin catalog and configuration previews"], responses={
    status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 409, 413, 503)
})


@router.get("/catalog", response_model=PluginCatalogResponse)
def catalog(core: Core, actor: Admin):
    return core.plugins.catalog(actor)


@router.post("/previews", response_model=PluginPreviewResponse, status_code=201)
def preview(body: PluginPreviewRequest, core: Core, actor: Admin):
    return core.plugins.preview(actor, body)


@router.get("/previews/{preview_id}", response_model=PluginPreviewResponse)
def saved_preview(preview_id: ObjectId, core: Core, actor: Admin):
    return core.plugins.get_preview(actor, preview_id)
