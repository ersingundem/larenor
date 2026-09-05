from typing import Annotated

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .auth import Principal
from .core import CoreServices
from .errors import ApiError


bearer = HTTPBearer(auto_error=False, scheme_name="DeviceAccessToken")


def get_core(request: Request) -> CoreServices:
    return request.app.state.core


def require_user(
    core: Annotated[CoreServices, Depends(get_core)],
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)],
) -> Principal:
    if (credentials is None or credentials.scheme.lower() != "bearer" or
            len(credentials.credentials) != 43):
        raise ApiError("invalid_session", 401)
    return core.auth.authenticate(credentials.credentials)


def require_ready_user(principal: Annotated[Principal, Depends(require_user)]) -> Principal:
    if principal.must_change_password:
        raise ApiError("password_change_required", 403)
    return principal


def require_admin(principal: Annotated[Principal, Depends(require_ready_user)]) -> Principal:
    if principal.role != "admin":
        raise ApiError("forbidden", 403)
    return principal
