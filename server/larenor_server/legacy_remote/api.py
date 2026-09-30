"""Admin-authenticated HTTP routes for opaque IR/RF controls."""

from typing import Annotated

from fastapi import APIRouter, Depends, Request

from ..auth import Principal
from ..dependencies import require_admin
from ..errors import ApiError
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .ha_provider import HomeAssistantRemoteSourceRequest, HomeAssistantRemoteCommandsRequest
from .models import (RemoteConfirmRequest, RemoteLearningRequest,
                     RemotePreviewRequest)


Admin = Annotated[Principal, Depends(require_admin)]
ROOT = "/admin/legacy-remotes/{core_id}/{home_id}"


def exact_request(request: Request):
    if request.scope.get("query_string") or len(request.headers.getlist("authorization")) > 1:
        raise ApiError("invalid_request")


router = APIRouter(
    tags=["Legacy smart remotes"],
    dependencies=[Depends(exact_request)],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 429, 503)
    },
)


def _gateway(request: Request):
    gateway = getattr(request.app.state, "legacy_remote_gateway", None)
    if gateway is None:
        raise ApiError("remote_provider_unavailable", 503)
    return gateway


@router.get(ROOT)
def catalog(core_id: Identity, home_id: Identity, actor: Admin, request: Request):
    return {"catalog": _gateway(request).catalog(actor, core_id, home_id)}


@router.get(ROOT + "/sources")
def sources(core_id: Identity, home_id: Identity, actor: Admin, request: Request):
    return _gateway(request).sources(actor, core_id, home_id)


@router.put(ROOT + "/sources/{source_id}")
def configure_source(
    core_id: Identity,
    home_id: Identity,
    source_id: Identity,
    body: HomeAssistantRemoteSourceRequest,
    actor: Admin,
    request: Request,
):
    return _gateway(request).configure_source(
        actor, core_id, home_id, source_id, body
    )


@router.patch(ROOT + "/sources/{source_id}/commands")
def update_commands(core_id: Identity, home_id: Identity, source_id: Identity,
                    body: HomeAssistantRemoteCommandsRequest, actor: Admin, request: Request):
    return _gateway(request).update_source_commands(actor, core_id, home_id, source_id, body)


@router.post(ROOT + "/previews", status_code=201)
def preview(
    core_id: Identity,
    home_id: Identity,
    body: RemotePreviewRequest,
    actor: Admin,
    request: Request,
):
    return {"preview": _gateway(request).preview(actor, core_id, home_id, body)}


@router.post(ROOT + "/previews/{request_id}/confirm")
def confirm(
    core_id: Identity,
    home_id: Identity,
    request_id: Identity,
    body: RemoteConfirmRequest,
    actor: Admin,
    request: Request,
):
    return {"result": _gateway(request).confirm(actor, core_id, home_id, request_id, body)}


@router.get(ROOT + "/results/{request_id}")
def result(
    core_id: Identity,
    home_id: Identity,
    request_id: Identity,
    actor: Admin,
    request: Request,
):
    return {"result": _gateway(request).result(actor, core_id, home_id, request_id)}


@router.post(ROOT + "/learnings", status_code=201)
def learn(
    core_id: Identity,
    home_id: Identity,
    body: RemoteLearningRequest,
    actor: Admin,
    request: Request,
):
    return {"learning": _gateway(request).learn(actor, core_id, home_id, body)}


@router.get(ROOT + "/learnings/{request_id}")
def learning_result(
    core_id: Identity,
    home_id: Identity,
    request_id: Identity,
    actor: Admin,
    request: Request,
):
    return {
        "learning": _gateway(request).learning_result(
            actor, core_id, home_id, request_id
        )
    }
