"""Admin-only verified component update inventory API."""

from typing import Annotated

from fastapi import APIRouter, Depends
from starlette.concurrency import run_in_threadpool

from ..auth import Principal
from ..dependencies import require_admin
from ..models import ErrorResponse
from .component_update_service import ComponentUpdateService
from .component_updates import ComponentUpdateInventory


Admin = Annotated[Principal, Depends(require_admin)]


def build_component_update_router(service: ComponentUpdateService) -> APIRouter:
    router = APIRouter(
        prefix="/admin/component-updates",
        tags=["Verified component updates"],
        responses={
            503: {
                "model": ErrorResponse,
                "description": "Component update worker or verified catalog unavailable",
            }
        },
    )

    @router.get("", response_model=ComponentUpdateInventory)
    async def inventory(_principal: Admin):
        return await run_in_threadpool(service.inventory)

    return router
