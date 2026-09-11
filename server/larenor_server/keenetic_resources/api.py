"""Admin binding workflow and resource-authorized Keenetic snapshots."""
import asyncio
import re
from threading import Event
from typing import Annotated

from fastapi import APIRouter, Depends, Request, Response
from fastapi.security import HTTPAuthorizationCredentials

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import bearer, get_core, require_user
from ..errors import ApiError
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import (
    BindingPreviewRequest,
    BindingResponse,
    ConfirmRequest,
    DetailsPage,
    PreviewResponse,
    SnapshotResponse,
    TopologyResponse,
)

Core = Annotated[CoreServices, Depends(get_core)]


def adapter_ready(core: Core, credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)]):
    try:
        actor = require_user(core, credentials)
    except ApiError as error:
        if error.code == "invalid_session" and credentials is not None and len(credentials.credentials) == 43:
            core.keenetic_resources.retire_invalid_session(credentials.credentials)
        raise
    if actor.must_change_password:
        raise ApiError("password_change_required", 403)
    return actor


Ready = Annotated[Principal, Depends(adapter_ready)]


def adapter_admin(actor: Ready):
    if actor.role != "admin":
        raise ApiError("forbidden", 403)
    return actor


Admin = Annotated[Principal, Depends(adapter_admin)]


def exact_request(request: Request):
    if len(request.headers.getlist("authorization")) > 1:
        raise ApiError("invalid_request")
    if not request.scope.get("query_string"):
        return
    pairs = list(request.query_params.multi_items())
    values = dict(pairs)
    details = request.method == "GET" and request.url.path.endswith("/details")
    if (not details or len(pairs) != len(values) or not 1 <= len(values) <= 3
            or not set(values) <= {"limit", "after", "expectedSnapshot"}
            or "limit" in values and (
                re.fullmatch(r"[1-9][0-9]{0,2}", values["limit"]) is None
                or int(values["limit"]) > 100)
            or ("after" in values) != ("expectedSnapshot" in values)
            or "after" in values and (
                re.fullmatch(r"[0-9a-f]{64}", values["after"]) is None
                or re.fullmatch(r"[0-9a-f]{64}", values["expectedSnapshot"]) is None)):
        raise ApiError("invalid_request")


router = APIRouter(tags=["Keenetic home resources"], dependencies=[Depends(exact_request)],
    responses={s: {"model": ErrorResponse} for s in (400, 401, 403, 404, 408, 409, 413, 429, 502, 503)})
PUBLIC = "/keenetic/{core_id}/{home_id}/resources/{resource_id}"
ADMIN = "/admin" + PUBLIC


async def observe(request, operation):
    cancelled = Event()
    async def monitor():
        while not cancelled.is_set():
            if await request.is_disconnected():
                cancelled.set(); return
            await asyncio.sleep(0.05)
    watcher = asyncio.create_task(monitor())
    try:
        return await asyncio.to_thread(operation, cancelled.is_set)
    finally:
        cancelled.set(); watcher.cancel()
        try:
            await watcher
        except asyncio.CancelledError:
            pass


@router.get(ADMIN + "/binding", response_model=BindingResponse)
def binding(core_id: Identity, home_id: Identity, resource_id: Identity,
            actor: Admin, core: Core):
    return core.keenetic_resources.binding(actor, core_id, home_id, resource_id)


@router.post(ADMIN + "/binding-preview", response_model=PreviewResponse, status_code=201)
async def preview(core_id: Identity, home_id: Identity, resource_id: Identity,
                  body: BindingPreviewRequest, request: Request, actor: Admin, core: Core):
    return await observe(request, lambda cancelled: core.keenetic_resources.preview(
        actor, core_id, home_id, resource_id, body, cancelled=cancelled))


@router.post(ADMIN + "/binding-confirm", response_model=BindingResponse, status_code=201)
def confirm(core_id: Identity, home_id: Identity, resource_id: Identity,
            body: ConfirmRequest, actor: Admin, core: Core):
    return core.keenetic_resources.confirm(actor, core_id, home_id, resource_id, body.previewId)


@router.delete(ADMIN + "/binding-preview/{preview_id}", status_code=204)
def cancel(core_id: Identity, home_id: Identity, resource_id: Identity,
           preview_id: Identity, actor: Admin, core: Core):
    core.keenetic_resources.cancel_preview(actor, core_id, home_id, resource_id, preview_id)
    return Response(status_code=204)


@router.get(PUBLIC + "/snapshot", response_model=SnapshotResponse)
async def snapshot(core_id: Identity, home_id: Identity, resource_id: Identity,
                   request: Request, actor: Ready, core: Core):
    return await observe(request, lambda cancelled: core.keenetic_resources.snapshot(
        actor, core_id, home_id, resource_id, cancelled=cancelled))


@router.get(PUBLIC + "/details", response_model=DetailsPage)
async def details(core_id: Identity, home_id: Identity, resource_id: Identity,
                  request: Request, actor: Ready, core: Core, limit: int = 25,
                  after: str | None = None, expectedSnapshot: str | None = None):
    return await observe(request, lambda cancelled: core.keenetic_resources.details_page(
        actor, core_id, home_id, resource_id, limit=limit, after=after,
        expected_snapshot=expectedSnapshot, cancelled=cancelled))


@router.get(PUBLIC + "/topology", response_model=TopologyResponse)
async def topology(core_id: Identity, home_id: Identity, resource_id: Identity,
                   request: Request, actor: Ready, core: Core):
    return await observe(request, lambda cancelled: core.keenetic_resources.topology(
        actor, core_id, home_id, resource_id, cancelled=cancelled))
