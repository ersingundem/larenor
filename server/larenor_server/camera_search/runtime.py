"""Runtime contract shared by the immutable test index and real provider."""

from __future__ import annotations
from collections.abc import Callable
from typing import TYPE_CHECKING
from ..auth import Principal
from ..errors import ApiError
from .index import CameraSearchIndex
from .models import (CameraSearchAuthority, CameraSearchContextResponse,
                     CameraSearchFeedbackRequest, CameraSearchFeedbackResponse,
                     CameraSearchPage, CameraSearchRequest)
if TYPE_CHECKING:
    from ..core import CoreServices

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
        core.auth.rate_limit([("camera_search_read", actor.id, 120)])
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
        if self._index.revision != request.expectedIndexRevision:
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
        feedback = getattr(core, "camera_search_feedback", None)
        if feedback is None:
            raise ApiError("service_unavailable", 503)
        filtered = feedback.filter_reported(actor, request.query, result.results)
        return result.model_copy(update={"results": filtered})

    def feedback(
        self,
        core: CoreServices,
        actor: Principal,
        core_id: str,
        home_id: str,
        body: CameraSearchFeedbackRequest,
    ) -> CameraSearchFeedbackResponse:
        if core.context.coreId != core_id or core.context.homeId != home_id:
            raise ApiError("not_found", 404)
        with core.db.connection() as connection:
            core.auth.assert_current(connection, actor)
        core.auth.rate_limit([("camera_search_feedback", actor.id, 120)])
        authority = self._authority(actor, core_id, home_id)
        evidence = body.evidence
        if (
            body.expectedIndexRevision != self._index.revision
            or evidence.coreId != core_id
            or evidence.homeId != home_id
            or evidence.cameraId not in set(authority.accessibleCameraIds)
            or evidence.indexRevision != body.expectedIndexRevision
        ):
            raise ApiError("revision_conflict", 409)
        feedback = getattr(core, "camera_search_feedback", None)
        if feedback is None:
            raise ApiError("service_unavailable", 503)
        result = feedback.record(actor, body)
        with core.db.connection() as connection:
            core.auth.assert_current(connection, actor)
        if self._authority(actor, core_id, home_id) != authority:
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
