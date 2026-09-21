"""Authenticated HTTP boundary for privacy-scoped camera metadata search."""

from collections.abc import Callable
from typing import Annotated

from fastapi import APIRouter, Depends, Request

from ..auth import Principal
from ..core import CoreServices
from ..dependencies import get_core, require_ready_user
from ..errors import ApiError
from ..models import ErrorResponse
from .index import CameraSearchIndex
from .models import (
    CameraSearchAuthority,
    CameraSearchContextResponse,
    CameraSearchPage,
    CameraSearchRequest,
    Identity,
)


AuthorityResolver = Callable[[Principal, str, str], CameraSearchAuthority | None]


class CameraSearchRuntime:
    """Binds the immutable index to server-owned live account authority."""

    def __init__(
        self,
        *,
        index: CameraSearchIndex,
        authorityResolver: AuthorityResolver,
    ):
        self._index = index
        self._resolve_authority = authorityResolver

    @staticmethod
    def _validate_scope(
        authority: CameraSearchAuthority,
        actor: Principal,
        core_id: str,
        home_id: str,
    ) -> None:
        if authority.coreId != core_id or authority.homeId != home_id:
            raise ApiError("not_found", 404)
        if (
            authority.accountId != actor.id
            or authority.sessionFamilyId != actor.family_id
            or authority.role != actor.role
            or not authority.active
            or not authority.canSearch
        ):
            raise ApiError("forbidden", 403)

    def _authority(
        self, actor: Principal, core_id: str, home_id: str
    ) -> CameraSearchAuthority:
        try:
            raw = self._resolve_authority(actor, core_id, home_id)
        except Exception:
            raise ApiError("service_unavailable", 503) from None
        if raw is None:
            raise ApiError("forbidden", 403)
        try:
            authority = CameraSearchAuthority.model_validate(raw)
        except (TypeError, ValueError):
            raise ApiError("forbidden", 403) from None
        self._validate_scope(authority, actor, core_id, home_id)
        return authority

    def search(
        self,
        core: CoreServices,
        actor: Principal,
        core_id: str,
        home_id: str,
        request: CameraSearchRequest,
    ) -> CameraSearchPage:
        if core.context.coreId != core_id or core.context.homeId != home_id:
            raise ApiError("not_found", 404)
        with core.db.connection() as connection:
            core.auth.assert_current(connection, actor)
        authority = self._authority(actor, core_id, home_id)
        result = self._index.search(authority, request)

        # A planner may take time. Re-resolve both token and membership before
        # publishing any evidence; computed results never outlive authority.
        with core.db.connection() as connection:
            core.auth.assert_current(connection, actor)
        if self._authority(actor, core_id, home_id) != authority:
            raise ApiError("revision_conflict", 409)
        if result.indexRevision != request.expectedIndexRevision:
            raise ApiError("revision_conflict", 409)
        allowed = set(authority.accessibleCameraIds)
        if any(
            match.evidence.coreId != core_id
            or match.evidence.homeId != home_id
            or match.evidence.cameraId not in allowed
            or match.evidence.indexRevision != request.expectedIndexRevision
            for match in result.results
        ):
            raise ApiError("revision_conflict", 409)
        return result

    def context(
        self,
        core: CoreServices,
        actor: Principal,
        core_id: str,
        home_id: str,
    ) -> CameraSearchContextResponse:
        if core.context.coreId != core_id or core.context.homeId != home_id:
            raise ApiError("not_found", 404)
        with core.db.connection() as connection:
            core.auth.assert_current(connection, actor)
        authority = self._authority(actor, core_id, home_id)
        return CameraSearchContextResponse(
            schemaVersion=1,
            coreId=core_id,
            homeId=home_id,
            indexRevision=self._index.revision,
            cameraIds=authority.accessibleCameraIds,
            maxWindowDays=31,
        )


def get_camera_search_runtime(request: Request) -> CameraSearchRuntime:
    runtime = getattr(request.app.state, "camera_search_runtime", None)
    if not isinstance(runtime, CameraSearchRuntime):
        raise ApiError("service_unavailable", 503)
    return runtime


Core = Annotated[CoreServices, Depends(get_core)]
Ready = Annotated[Principal, Depends(require_ready_user)]
Runtime = Annotated[CameraSearchRuntime, Depends(get_camera_search_runtime)]

router = APIRouter(
    tags=["Camera recording search"],
    responses={
        status: {"model": ErrorResponse}
        for status in (400, 401, 403, 404, 409, 413, 429, 503)
    },
)


@router.get(
    "/camera-search/{core_id}/{home_id}/context",
    response_model=CameraSearchContextResponse,
)
def camera_search_context(
    core_id: Identity,
    home_id: Identity,
    actor: Ready,
    core: Core,
    runtime: Runtime,
):
    return runtime.context(core, actor, core_id, home_id)


@router.post(
    "/camera-search/{core_id}/{home_id}/search",
    response_model=CameraSearchPage,
)
def search_camera_metadata(
    core_id: Identity,
    home_id: Identity,
    body: CameraSearchRequest,
    actor: Ready,
    core: Core,
    runtime: Runtime,
):
    return runtime.search(core, actor, core_id, home_id, body)
