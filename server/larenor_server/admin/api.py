from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_admin
from ..errors import ApiError
from ..models import ErrorResponse
from .models import (AdminUserResponse, AuditResponse, CreateUserRequest, ObjectId,
                     ResetPasswordRequest, SessionsResponse, UpdateUserRequest, UsersResponse)


Core = Annotated[CoreServices, Depends(get_core)]
Admin = Annotated[Principal, Depends(require_admin)]
Limit = Annotated[int, Query(ge=1, le=100)]
router = APIRouter(prefix="/admin", tags=["Administration"], responses={
    status: {"model": ErrorResponse} for status in (400, 401, 403, 404, 409, 413, 429, 503)
})


@router.get("/users", response_model=UsersResponse)
def users(core: Core, actor: Admin):
    return core.admin.users(actor)


@router.post("/users", response_model=AdminUserResponse, status_code=201)
def create_user(body: CreateUserRequest, core: Core, actor: Admin):
    return core.admin.create_user(actor, body)


@router.patch("/users/{user_id}", response_model=AdminUserResponse)
def update_user(user_id: ObjectId, body: UpdateUserRequest, core: Core, actor: Admin):
    return core.admin.update_user(actor, user_id, body)


@router.post("/users/{user_id}/password", response_model=AdminUserResponse)
def reset_password(user_id: ObjectId, body: ResetPasswordRequest, core: Core, actor: Admin):
    return core.admin.reset_password(actor, user_id, body)


@router.get("/sessions", response_model=SessionsResponse)
def sessions(core: Core, actor: Admin, userId: ObjectId | None = None,
             cursor: ObjectId | None = None, limit: Limit = 50):
    return core.admin.sessions(actor, user_id=userId, cursor=cursor, limit=limit)


@router.delete("/sessions/{family_id}", status_code=204)
def revoke_session(family_id: ObjectId, core: Core, actor: Admin):
    core.admin.revoke_session(actor, family_id)
    return Response(status_code=204)


@router.get("/audit", response_model=AuditResponse)
def audit(core: Core, actor: Admin,
          cursor: Annotated[str | None, Query(pattern=r"^[1-9][0-9]{0,18}$")] = None, limit: Limit = 50):
    if cursor is not None and int(cursor) > 2**63 - 1:
        raise ApiError("invalid_request", 400)
    return core.admin.audit(actor, cursor=int(cursor) if cursor else None, limit=limit)
