"""Admin-only Core HTTP surface for revision-bound Keenetic commands."""

from typing import Annotated

from fastapi import APIRouter, Depends, Request
from pydantic import Field

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin
from ..errors import ApiError
from ..home_resources.models import FrozenModel, Identity
from ..models import ErrorResponse
from .models import CommandRequest


Core = Annotated[CoreServices, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
ROOT = "/admin/homes/{core_id}/{home_id}/resources/{resource_id}/keenetic/commands"


class ConfirmBody(FrozenModel):
    token: str = Field(min_length=43, max_length=43, pattern=r"^[A-Za-z0-9_-]{43}$")


def exact_request(request: Request):
    if request.scope.get("query_string") or len(request.headers.getlist("authorization")) > 1:
        raise ApiError("invalid_request")


router = APIRouter(
    tags=["Keenetic command authority"],
    dependencies=[Depends(exact_request)],
    responses={status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 409, 429, 503)},
)


def _scope(body, core_id, home_id, resource_id):
    target = body.target
    if (target.coreId, target.homeId, target.resourceId) != (core_id, home_id, resource_id):
        raise ApiError("not_found", 404)


@router.post(ROOT + "/preview")
def preview(core_id: Identity, home_id: Identity, resource_id: Identity,
            body: CommandRequest, actor: Admin, core: Core):
    _scope(body, core_id, home_id, resource_id)
    return core.keenetic_commands.preview(actor, body)


@router.post(ROOT + "/{preview_id}/confirm")
def confirm(core_id: Identity, home_id: Identity, resource_id: Identity,
            preview_id: Identity, body: ConfirmBody, actor: Admin, core: Core):
    return core.keenetic_commands.confirm(
        actor, preview_id, body.token, (core_id, home_id, resource_id)
    )


@router.post(ROOT + "/{preview_id}/cancel")
def cancel(core_id: Identity, home_id: Identity, resource_id: Identity,
           preview_id: Identity, actor: Admin, core: Core):
    return core.keenetic_commands.cancel(
        actor, preview_id, (core_id, home_id, resource_id)
    )


@router.get(ROOT + "/status/{request_id}")
def status(core_id: Identity, home_id: Identity, resource_id: Identity,
           request_id: Identity, actor: Admin, core: Core):
    result = core.keenetic_command_journal.status(actor, request_id)
    target = result["command"]["target"]
    if (target["coreId"], target["homeId"], target["resourceId"]) != (core_id, home_id, resource_id):
        raise ApiError("not_found", 404)
    return result


@router.get(ROOT + "/history")
def history(core_id: Identity, home_id: Identity, resource_id: Identity,
            actor: Admin, core: Core):
    if (core_id, home_id) != (core.context.coreId, core.context.homeId):
        raise ApiError("not_found", 404)
    return core.keenetic_command_journal.history(actor, resource_id)


@router.get(ROOT + "/integrity")
def integrity(core_id: Identity, home_id: Identity, resource_id: Identity,
              actor: Admin, core: Core):
    if (core_id, home_id) != (core.context.coreId, core.context.homeId):
        raise ApiError("not_found", 404)
    # Resource stays in the path to prevent a Client from detaching the audit
    # control from the page it is reviewing. The checkpoint covers all commands.
    return core.keenetic_command_journal.integrity(actor)
