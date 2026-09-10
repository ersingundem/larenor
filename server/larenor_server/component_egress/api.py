from typing import Annotated
from fastapi import APIRouter, Depends, Request
from ..admin.models import ObjectId
from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin
from ..errors import ApiError
from .models import Response, Update

Core = Annotated[CoreServices, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(prefix='/admin/services', tags=['Component outbound policy'])


def _closed(request):
    if request.query_params or len(request.headers.getlist('authorization')) != 1:
        raise ApiError('invalid_request')


@router.get('/{service_id}/outbound-policy', response_model=Response)
def read(service_id: ObjectId, request: Request, actor: Admin, core: Core):
    _closed(request)
    return core.component_egress.read(actor, service_id)


@router.put('/{service_id}/outbound-policy', response_model=Response)
def update(service_id: ObjectId, body: Update, request: Request, actor: Admin, core: Core):
    _closed(request)
    return core.component_egress.update(actor, service_id, body)
