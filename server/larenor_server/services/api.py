from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response

from ..admin.models import ObjectId
from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse
from .models import CreateServiceRequest, ServiceResponse, ServicesResponse, UpdateServiceRequest


Core = Annotated[CoreServices, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(prefix="/admin/services", tags=["Service connections"], responses={
    status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 409, 413, 503)
})


@router.get("", response_model=ServicesResponse)
def services(core: Core, actor: Admin):
    return core.services.list(actor)


@router.post("", response_model=ServiceResponse, status_code=201)
def create_service(body: CreateServiceRequest, core: Core, actor: Admin):
    return core.services.create(actor, body)


@router.patch("/{service_id}", response_model=ServiceResponse)
def update_service(service_id: ObjectId, body: UpdateServiceRequest, core: Core, actor: Admin):
    return core.services.update(actor, service_id, body)


@router.delete("/{service_id}", status_code=204)
def delete_service(service_id: ObjectId, expectedRevision: Annotated[int, Query(ge=1, le=2**63 - 1)],
                   core: Core, actor: Admin):
    core.services.delete(actor, service_id, expectedRevision)
    return Response(status_code=204)
