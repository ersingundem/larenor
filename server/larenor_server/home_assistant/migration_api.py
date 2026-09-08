"""Closed admin-only explicit Direct credential migration; no provider proxy."""
from fastapi import APIRouter, Depends, Request, Response

from ..home_resources.models import Identity
from .api import Admin, Core, ADMIN, exact_request, observe
from .migration_models import (MigrationInput, MigrationConfirm,
                               MigrationPreviewResponse, MigrationReceiptResponse)

router = APIRouter(tags=['Explicit Direct HA migration'], dependencies=[Depends(exact_request)])
BASE = ADMIN+'/direct-migration'


@router.post(BASE+'/preview', status_code=201, response_model=MigrationPreviewResponse)
async def preview(core_id: Identity, home_id: Identity, resource_id: Identity,
                  body: MigrationInput, request: Request, actor: Admin, core: Core):
    return await observe(request, lambda cancelled: core.direct_ha_migration.preview(
        actor, core_id, home_id, resource_id, body, cancelled=cancelled))


@router.delete(BASE+'/preview/{preview_id}', status_code=204)
def cancel(core_id: Identity, home_id: Identity, resource_id: Identity,
           preview_id: Identity, actor: Admin, core: Core):
    core.direct_ha_migration.cancel(actor, core_id, home_id, resource_id, preview_id)
    return Response(status_code=204)


@router.post(BASE+'/confirm', status_code=201, response_model=MigrationReceiptResponse)
def confirm(core_id: Identity, home_id: Identity, resource_id: Identity,
            body: MigrationConfirm, actor: Admin, core: Core):
    return core.direct_ha_migration.confirm(actor, core_id, home_id, resource_id, body)


@router.get(BASE+'/results/{request_id}', response_model=MigrationReceiptResponse)
def result(core_id: Identity, home_id: Identity, resource_id: Identity,
           request_id: Identity, actor: Admin, core: Core):
    return core.direct_ha_migration.result(actor, core_id, home_id, resource_id, request_id)
