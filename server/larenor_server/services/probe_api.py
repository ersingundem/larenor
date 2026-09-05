from typing import Annotated

from fastapi import APIRouter, Depends

from ..admin.models import ObjectId, Revision
from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin
from ..models import ErrorResponse, StrictModel
from .models import ServiceResponse


class CheckServiceRequest(StrictModel):
    expectedRevision: Revision


Core = Annotated[CoreServices, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(prefix="/admin/services", tags=["Service connections"], responses={
    status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 409, 413, 429, 503)
})


@router.post("/{service_id}/check", response_model=ServiceResponse,
             summary="Check service identity and authentication without changing devices",
             description="Runs a bounded connection check against the saved configuration. "
                         "Provider login may create a short-lived session. Does not install services "
                         "or change media, devices or provider settings. The observation remains "
                         "bound to the checked revision and is not a device-operation result.")
def check_service(service_id: ObjectId, body: CheckServiceRequest, core: Core, actor: Admin):
    return core.service_probe.check(actor, service_id, body.expectedRevision)
