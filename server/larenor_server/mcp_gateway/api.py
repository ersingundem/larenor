import json
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Request, Response
from pydantic import TypeAdapter, ValidationError
from starlette.responses import JSONResponse

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..errors import ApiError
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    ClientId,
    CreateGrant,
    McpInitializedNotification,
    McpRequest,
    RevokeGrant,
)


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    tags=["Authorized MCP gateway"],
    responses={status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 409, 429, 503)},
)
ROOT = "/mcp-gateway/{core_id}/{home_id}"
PROTOCOL_VERSION = "2025-06-18"
CLIENT_ID_ADAPTER = TypeAdapter(ClientId)


def _protocol_error(request_id, code, message, *, status_code=200):
    return JSONResponse(
        {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}},
        status_code=status_code,
    )


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
async def mcp(
    core_id: Identity,
    home_id: Identity,
    request: Request,
    core: Core,
    authorization: Annotated[str | None, Header()] = None,
    client_id: Annotated[str | None, Header(alias="X-Larenor-MCP-Client")] = None,
    protocol_version: Annotated[str | None, Header(alias="MCP-Protocol-Version")] = None,
    origin: Annotated[str | None, Header()] = None,
):
    if authorization is None or not authorization.startswith("Bearer ") or client_id is None:
        raise ApiError("invalid_mcp_token", 401)
    try:
        client_id = CLIENT_ID_ADAPTER.validate_python(client_id, strict=True)
    except ValidationError:
        raise ApiError("invalid_mcp_token", 401) from None
    if origin is not None:
        raise ApiError("forbidden", 403)
    if protocol_version is not None and protocol_version != PROTOCOL_VERSION:
        return _protocol_error(None, -32600, "Invalid Request", status_code=400)
    try:
        body = await request.json()
    except (json.JSONDecodeError, UnicodeDecodeError):
        return _protocol_error(None, -32700, "Parse error")
    if not isinstance(body, dict):
        return _protocol_error(None, -32600, "Invalid Request")
    try:
        notification = McpInitializedNotification.model_validate(body)
    except ValidationError:
        notification = None
    if notification is not None:
        core.mcp_gateway.accept_initialized(
            authorization[7:], client_id, core_id, home_id, notification
        )
        return Response(status_code=202)
    try:
        request_body = McpRequest.model_validate(body)
    except ValidationError:
        return _protocol_error(None, -32600, "Invalid Request")
    return core.mcp_gateway.dispatch(
        authorization[7:], client_id, core_id, home_id, request_body
    )
