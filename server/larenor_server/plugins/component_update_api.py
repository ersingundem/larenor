"""Admin-only verified component update inventory API."""

from typing import Annotated

from fastapi import APIRouter, Depends
from starlette.concurrency import run_in_threadpool

from ..auth import Principal
from ..dependencies import require_admin
from ..models import ErrorResponse
from .component_update_service import ComponentUpdateService
from .component_updates import (
    ComponentReleasePreference,
    ComponentUpdateInventory,
    PutComponentReleasePreference,
)
from .models import ServiceId


Admin = Annotated[Principal, Depends(require_admin)]


def build_component_update_router(service: ComponentUpdateService) -> APIRouter:
    router = APIRouter(
        prefix="/admin/component-updates",
        tags=["Verified component updates"],
        responses={
            status: {"model": ErrorResponse}
            for status in (400, 401, 403, 404, 409, 429, 503)
        },
    )

    @router.get("", response_model=ComponentUpdateInventory)
    async def inventory(principal: Admin):
        return await run_in_threadpool(service.inventory, principal)

    @router.put(
        "/{service_id}/preference",
        response_model=ComponentReleasePreference,
    )
    async def put_preference(
        service_id: ServiceId,
        body: PutComponentReleasePreference,
        principal: Admin,
    ):
        return await run_in_threadpool(
            service.put_preference,
            principal,
            service_id,
            body,
        )

    return router
