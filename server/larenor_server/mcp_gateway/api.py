from typing import Annotated

from fastapi import APIRouter, Depends, Header

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..errors import ApiError
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import ClientId, CreateGrant, McpRequest, RevokeGrant


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    tags=["Authorized MCP gateway"],
    responses={status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 409, 429, 503)},
)
ROOT = "/mcp-gateway/{core_id}/{home_id}"


@router.get(ROOT + "/grants")
def grants(core_id: Identity, home_id: Identity, actor: Admin, core: Core):
    return core.mcp_gateway.list(actor, core_id, home_id)


@router.post(ROOT + "/grants", status_code=201)
def create_grant(core_id: Identity, home_id: Identity, body: CreateGrant, actor: Admin, core: Core):
    return core.mcp_gateway.create(actor, core_id, home_id, body)


@router.post(ROOT + "/grants/{grant_id}/revoke")
def revoke_grant(
    core_id: Identity, home_id: Identity, grant_id: Identity, body: RevokeGrant, actor: Admin, core: Core
):
    return core.mcp_gateway.revoke(actor, core_id, home_id, grant_id, body)


@router.post(ROOT + "/mcp")
def mcp(
    core_id: Identity,
    home_id: Identity,
    body: McpRequest,
    core: Core,
    authorization: Annotated[str | None, Header()] = None,
    client_id: Annotated[ClientId | None, Header(alias="X-Larenor-MCP-Client")] = None,
):
    if authorization is None or not authorization.startswith("Bearer ") or client_id is None:
        raise ApiError("invalid_mcp_token", 401)
    return core.mcp_gateway.dispatch(authorization[7:], client_id, core_id, home_id, body)
