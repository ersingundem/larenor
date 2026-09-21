from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Response
from pydantic import Field

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..home_resources.models import FrozenModel, Identity
from ..models import ErrorResponse


Revision = Annotated[int, Field(ge=1, le=2**63 - 1)]
Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]


class AuthorityRequest(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    accountId: Identity
    sessionId: Identity
    coreRevision: Revision
    homeRevision: Revision
    accountRevision: Revision
    membersRevision: Revision
    resourceId: Identity
    resourceRevision: Revision
    expectedCalendarRevision: Revision

    def authority_fields(self):
        return {
            name: getattr(self, name)
            for name in (
                "coreId", "homeId", "accountId", "sessionId", "coreRevision",
                "homeRevision", "accountRevision", "membersRevision",
                "resourceId", "resourceRevision", "expectedCalendarRevision",
            )
        }


class SnapshotRequest(AuthorityRequest):
    pass


class Recurrence(FrozenModel):
    frequency: Literal["none", "daily", "weekly"]
    count: Annotated[int, Field(ge=1, le=64)]


class CreateRequest(AuthorityRequest):
    commandId: Identity
    timezone: str = Field(min_length=1, max_length=128)
    localStart: str = Field(min_length=19, max_length=19)
    fold: Literal[0, 1]
    durationSeconds: Annotated[int, Field(ge=60, le=86400)]
    units: Annotated[int, Field(ge=1, le=64)]
    recurrence: Recurrence

    def command(self, action):
        value = self.model_dump(exclude={"schemaVersion", "sessionId"})
        value["action"] = action
        return value


class CancelRequest(AuthorityRequest):
    commandId: Identity
    reservationId: Identity

    def command(self, action):
        value = self.model_dump(exclude={"schemaVersion", "sessionId"})
        value["action"] = action
        return value


class ExportRequest(AuthorityRequest):
    limit: Annotated[int, Field(ge=1, le=256)]


router = APIRouter(
    tags=["Shared resource reservations"],
    responses={status: {"model": ErrorResponse}
               for status in (400, 401, 403, 404, 409, 413, 429, 503)},
)
ROOT = "/resource-reservations/{core_id}/{home_id}"


@router.get(ROOT + "/authority")
def bootstrap(core_id: Identity, home_id: Identity, actor: Ready, core: Core):
    return core.resource_reservations.bootstrap(actor, core_id, home_id)


@router.post(ROOT + "/{resource_id}/snapshot")
def snapshot(core_id: Identity, home_id: Identity, resource_id: Identity,
             body: SnapshotRequest, actor: Ready, core: Core):
    return core.resource_reservations.snapshot(
        actor, core_id, home_id, resource_id, body,
    )


@router.post(ROOT + "/{resource_id}/commands/create")
def create(core_id: Identity, home_id: Identity, resource_id: Identity,
           body: CreateRequest, actor: Ready, core: Core):
    return core.resource_reservations.create(actor, core_id, home_id, resource_id, body)


@router.post(ROOT + "/{resource_id}/commands/cancel")
def cancel(core_id: Identity, home_id: Identity, resource_id: Identity,
           body: CancelRequest, actor: Ready, core: Core):
    return core.resource_reservations.cancel(actor, core_id, home_id, resource_id, body)


@router.post(ROOT + "/{resource_id}/receipts/{command_id}")
def receipt(core_id: Identity, home_id: Identity, resource_id: Identity,
            command_id: Identity, body: SnapshotRequest, actor: Ready, core: Core,
            response: Response):
    value = core.resource_reservations.receipt(
        actor, core_id, home_id, resource_id, command_id, body,
    )
    if value is None:
        response.status_code = 204
    return value


@router.post(ROOT + "/{resource_id}/export")
def export(core_id: Identity, home_id: Identity, resource_id: Identity,
           body: ExportRequest, actor: Ready, core: Core):
    return core.resource_reservations.export(actor, core_id, home_id, resource_id, body)
