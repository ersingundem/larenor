"""Fail-closed authenticated adapter for presence-informed camera profiles."""

from ..errors import ApiError
from .http_models import CameraProfileApplyRequest, CameraProfileSnapshot
from .models import (
    CameraPrivacyBoundary,
    CameraProfileAuthority,
    CameraProfilePolicy,
    CameraProviderSupport,
    CameraReadback,
    PresenceSignal,
)


class CameraProfileHttpGateway:
    def __init__(self, *, engine, coordinator, provider, clockMs, coreId, homeId):
        self._engine = engine
        self._coordinator = coordinator
        self._provider = provider
        self._clock_ms = clockMs
        self._core_id = coreId
        self._home_id = homeId

    @staticmethod
    def _actor(authority, actor, core_id, home_id):
        if (authority.coreId, authority.homeId) != (core_id, home_id):
            raise ApiError("not_found", 404)
        if (
            authority.accountId != actor.id
            or authority.sessionFamilyId != actor.family_id
            or authority.role != "admin"
            or actor.role != "admin"
            or not authority.active
            or not authority.canManageCameraProfiles
        ):
            raise ApiError("forbidden", 403)

    def _snapshot(self, actor, core_id, home_id, *, evaluated_at=None):
        try:
            raw = self._provider.snapshot(actor)
            if not isinstance(raw, (tuple, list)) or len(raw) != 5:
                raise ValueError
            authority = CameraProfileAuthority.model_validate(raw[0])
            policy = CameraProfilePolicy.model_validate(raw[1])
            signal = PresenceSignal.model_validate(raw[2])
            readbacks = [CameraReadback.model_validate(item) for item in raw[3]]
            support = [CameraProviderSupport.model_validate(item) for item in raw[4]]
        except ApiError:
            raise
        except Exception:
            raise ApiError("camera_profile_provider_unavailable", 503) from None
        self._actor(authority, actor, core_id, home_id)
        if (core_id, home_id) != (self._core_id, self._home_id):
            raise ApiError("not_found", 404)
        if (
            policy.coreId,
            policy.homeId,
            signal.coreId,
            signal.homeId,
        ) != (core_id, home_id, core_id, home_id):
            raise ApiError("revision_conflict", 409)
        targets = {item.cameraId: item for item in policy.cameras}
        observed = {item.camera.cameraId: item for item in readbacks}
        capabilities = {item.camera.cameraId: item for item in support}
        if (
            len(observed) != len(readbacks)
            or len(capabilities) != len(support)
            or set(observed) != set(targets)
            or set(capabilities) != set(targets)
        ):
            raise ApiError("revision_conflict", 409)
        for camera_id, scope in targets.items():
            if (
                observed[camera_id].camera != scope
                or capabilities[camera_id].camera != scope
                or (observed[camera_id].coreId, observed[camera_id].homeId)
                != (core_id, home_id)
            ):
                raise ApiError("revision_conflict", 409)
        now_ms = self._clock_ms() if evaluated_at is None else evaluated_at
        decision = self._engine.evaluate(authority, policy, signal, nowMs=now_ms)
        return CameraProfileSnapshot(
            schemaVersion=1,
            authority=authority,
            policy=policy,
            signal=signal,
            decision=decision,
            readbacks=readbacks,
            support=support,
            privacyBoundary=CameraPrivacyBoundary(),
        )

    def snapshot(self, actor, core_id, home_id):
        return self._snapshot(actor, core_id, home_id)

    def apply(self, actor, core_id, home_id, raw):
        try:
            request = CameraProfileApplyRequest.model_validate(raw)
        except ValueError:
            raise ApiError("invalid_request") from None
        current = self._snapshot(
            actor,
            core_id,
            home_id,
            evaluated_at=request.decision.evaluatedAtMs,
        )
        if (
            request.authority != current.authority
            or request.policy != current.policy
            or request.signal != current.signal
            or request.decision != current.decision
            or request.readbacks != current.readbacks
            or request.support != current.support
        ):
            raise ApiError("revision_conflict", 409)
        return self._coordinator.apply(
            request.authority,
            request.decision,
            request.readbacks,
            requestId=request.requestId,
            nowMs=self._clock_ms(),
            worker=self._provider.apply,
            rawSupports=request.support,
        )
