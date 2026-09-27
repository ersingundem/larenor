from typing import Annotated

from fastapi import APIRouter, Depends

from ..auth import Principal
from ..dependencies import get_core, require_admin
from ..home_resources.models import Identity
from ..models import ErrorResponse
from .models import CreateMiniPlugin, RenderMiniPlugin, StopMiniPlugin


Core = Annotated[object, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
router = APIRouter(
    tags=["Bounded mini plugins"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 429, 503)
    },
)
ROOT = "/mini-plugins/{core_id}/{home_id}"


@router.get(ROOT + "/catalog")
def catalog(core_id: Identity, home_id: Identity, actor: Admin, core: Core):
    # List goes through the same scope and admin gate before returning catalog data.
    core.mini_plugins.list(actor, core_id, home_id)
    return core.mini_plugins.catalog()


@router.get(ROOT)
def instances(core_id: Identity, home_id: Identity, actor: Admin, core: Core):
    return core.mini_plugins.list(actor, core_id, home_id)


@router.post(ROOT, status_code=201)
def create(
    core_id: Identity,
    home_id: Identity,
    body: CreateMiniPlugin,
    actor: Admin,
    core: Core,
):
    return core.mini_plugins.create(actor, core_id, home_id, body)


@router.post(ROOT + "/{plugin_id}/stop")
def stop(
    core_id: Identity,
    home_id: Identity,
    plugin_id: Identity,
    body: StopMiniPlugin,
    actor: Admin,
    core: Core,
):
    return core.mini_plugins.stop(actor, core_id, home_id, plugin_id, body)


@router.post(ROOT + "/{plugin_id}/render")
def render(
    core_id: Identity,
    home_id: Identity,
    plugin_id: Identity,
    body: RenderMiniPlugin,
    actor: Admin,
    core: Core,
):
    return core.mini_plugins.render(actor, core_id, home_id, plugin_id, body)
