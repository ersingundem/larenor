"""Fail-closed policy evaluation and one-shot provider command coordination."""

from dataclasses import dataclass
import hashlib
import json
import threading
from typing import Callable

from ..errors import ApiError
from .models import (
    CameraCommandReceipt,
    CameraCommandResult,
    CameraDesiredState,
    CameraProfileAuthority,
    CameraProfileDecision,
    CameraProfilePolicy,
    CameraReadback,
    CameraWorkerCommand,
    ManualCameraOverride,
    PresenceSignal,
    WorkerReadback,
)


@dataclass(frozen=True)
class _ObservedPresence:
    signal: PresenceSignal
    stable_since_ms: int


class CameraProfileEngine:
    """Presence selects a policy branch only after independent live authorization."""

    def __init__(self, *, authorityResolver: Callable, policyResolver: Callable):
        self._resolve_authority = authorityResolver
        self._resolve_policy = policyResolver
        self._signals: dict[str, _ObservedPresence] = {}

    def _authority(self, presented):
        try:
            value = CameraProfileAuthority.model_validate(presented)
        except ValueError:
            raise ApiError("invalid_request") from None
        try:
            current = self._resolve_authority(value.accountId)
            current = CameraProfileAuthority.model_validate(current)
        except Exception:
            raise ApiError("forbidden", 403) from None
        if current != value:
            raise ApiError("revision_conflict", 409)
        if not value.active or value.role != "admin" or not value.canManageCameraProfiles:
            raise ApiError("forbidden", 403)
        return value

    def _policy(self, presented):
        try:
            value = CameraProfilePolicy.model_validate(presented)
        except ValueError:
            raise ApiError("invalid_request") from None
        try:
            current = self._resolve_policy(value.profileId)
            current = CameraProfilePolicy.model_validate(current)
        except Exception:
            raise ApiError("revision_conflict", 409) from None
        if current != value:
            raise ApiError("revision_conflict", 409)
        if not value.active:
            raise ApiError("forbidden", 403)
        return value

    def _observe(self, profile_id: str, signal: PresenceSignal) -> _ObservedPresence:
        old = self._signals.get(profile_id)
        if old is not None:
            if signal.signalRevision < old.signal.signalRevision:
                raise ApiError("revision_conflict", 409)
            if signal.signalRevision == old.signal.signalRevision:
                if signal != old.signal:
                    raise ApiError("revision_conflict", 409)
                return old
            if signal.observedAtMs < old.signal.observedAtMs:
                raise ApiError("revision_conflict", 409)
        stable_since = signal.observedAtMs
        if old is not None and old.signal.state == signal.state:
            stable_since = old.stable_since_ms
        observed = _ObservedPresence(signal, stable_since)
        self._signals[profile_id] = observed
        return observed

    def evaluate(
        self,
        presentedAuthority: CameraProfileAuthority,
        presentedPolicy: CameraProfilePolicy,
        rawSignal: PresenceSignal,
        *,
        nowMs: int,
        manualOverride: ManualCameraOverride | None = None,
    ) -> CameraProfileDecision:
        authority = self._authority(presentedAuthority)
        policy = self._policy(presentedPolicy)
        try:
            signal = PresenceSignal.model_validate(rawSignal)
            if type(nowMs) is not int or nowMs < 0 or nowMs > 2**63 - 1:
                raise ValueError
        except ValueError:
            raise ApiError("invalid_request") from None
        if (policy.coreId, policy.homeId) != (authority.coreId, authority.homeId):
            raise ApiError("not_found", 404)
        if (signal.coreId, signal.homeId, signal.sourceId, signal.sourceRevision) != (
            policy.coreId, policy.homeId, policy.presenceSourceId, policy.presenceSourceRevision
        ):
            raise ApiError("revision_conflict", 409)
        if signal.observedAtMs > nowMs:
            raise ApiError("invalid_request")

        reason: str
        override = None
        if manualOverride is not None:
            try:
                override = ManualCameraOverride.model_validate(manualOverride)
            except ValueError:
                raise ApiError("invalid_request") from None
            if (override.coreId, override.homeId, override.profileId,
                    override.expectedProfileRevision, override.actorAccountId) != (
                policy.coreId, policy.homeId, policy.profileId,
                policy.profileRevision, authority.accountId
            ):
                raise ApiError("revision_conflict", 409)
            if override.createdAtMs > nowMs:
                raise ApiError("invalid_request")
        observed = self._observe(policy.profileId, signal)
        if override is not None:
            if nowMs < override.expiresAtMs:
                mode, reason = override.mode, "manual_override"
            else:
                mode, reason = policy.failSafeMode, "manual_override_expired"
        elif nowMs - signal.observedAtMs > policy.presenceMaxAgeMs:
            mode, reason = policy.failSafeMode, "presence_stale"
        elif signal.state == "unknown":
            mode, reason = policy.failSafeMode, "presence_unknown"
        else:
            delay = policy.enterDelayMs if signal.state == "home" else policy.exitDelayMs
            if nowMs - observed.stable_since_ms < delay + policy.hysteresisMs:
                mode, reason = policy.failSafeMode, "presence_stabilizing"
            elif signal.state == "home":
                mode, reason = policy.atHomeMode, "presence_home"
            else:
                mode, reason = policy.awayMode, "presence_away"
        policy_hash = hashlib.sha256(
            json.dumps(policy.model_dump(mode="json"), sort_keys=True,
                       separators=(",", ":")).encode()
        ).hexdigest()
        return CameraProfileDecision(
            schemaVersion=1,
            coreId=policy.coreId,
            homeId=policy.homeId,
            homeRevision=authority.homeRevision,
            profileId=policy.profileId,
            profileRevision=policy.profileRevision,
            policyHash=policy_hash,
            actorAccountId=authority.accountId,
            accountRevision=authority.accountRevision,
            sessionFamilyId=authority.sessionFamilyId,
            presenceSourceId=signal.sourceId,
            presenceSourceRevision=signal.sourceRevision,
            signalRevision=signal.signalRevision,
            evaluatedAtMs=nowMs,
            reason=reason,
            mode=mode,
            targets=[CameraDesiredState(schemaVersion=1, camera=item, mode=mode)
                     for item in policy.cameras],
        )


class CameraProfileCoordinator:
    """Dispatches each accepted command once; unknown effects require explicit review."""

    def __init__(self, *, audit, authorityResolver, policyResolver, maxBatches: int = 1024):
        if type(maxBatches) is not int or not 1 <= maxBatches <= 4096:
            raise ValueError("invalid_batch_limit")
        self._audit = audit
        self._resolve_authority = authorityResolver
        self._resolve_policy = policyResolver
        self._max_batches = maxBatches
        self._receipts: dict[str, tuple[str, CameraCommandReceipt]] = {}
        self._lock = threading.Lock()

    @staticmethod
    def _digest(decision):
        value = decision.model_dump(mode="json")
        return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    def apply(self, presentedAuthority, rawDecision, rawReadbacks, *, requestId, nowMs, worker):
        try:
            authority = CameraProfileAuthority.model_validate(presentedAuthority)
            decision = CameraProfileDecision.model_validate(rawDecision)
            readbacks = [CameraReadback.model_validate(item) for item in rawReadbacks]
            if (not isinstance(requestId, str) or len(requestId) != 32
                    or any(char not in "0123456789abcdef" for char in requestId)
                    or type(nowMs) is not int or nowMs < decision.evaluatedAtMs):
                raise ValueError
        except ValueError:
            raise ApiError("invalid_request") from None
        if not authority.active or authority.role != "admin" or not authority.canManageCameraProfiles:
            raise ApiError("forbidden", 403)
        if (
            authority.coreId, authority.homeId, authority.homeRevision,
            authority.accountId, authority.accountRevision, authority.sessionFamilyId,
        ) != (
            decision.coreId, decision.homeId, decision.homeRevision,
            decision.actorAccountId, decision.accountRevision, decision.sessionFamilyId,
        ):
            raise ApiError("revision_conflict", 409)
        try:
            current_authority = CameraProfileAuthority.model_validate(
                self._resolve_authority(authority.accountId)
            )
            current_policy = CameraProfilePolicy.model_validate(
                self._resolve_policy(decision.profileId)
            )
        except Exception:
            raise ApiError("forbidden", 403) from None
        if current_authority != authority:
            raise ApiError("revision_conflict", 409)
        current_policy_hash = hashlib.sha256(
            json.dumps(current_policy.model_dump(mode="json"), sort_keys=True,
                       separators=(",", ":")).encode()
        ).hexdigest()
        if current_policy_hash != decision.policyHash:
            raise ApiError("revision_conflict", 409)
        with self._lock:
            return self._apply_once(
                authority, decision, readbacks, requestId=requestId,
                nowMs=nowMs, worker=worker,
            )

    def _apply_once(self, authority, decision, readbacks, *, requestId, nowMs, worker):
        targets = {item.camera.cameraId: item for item in decision.targets}
        current = {item.camera.cameraId: item for item in readbacks}
        if len(current) != len(readbacks) or set(current) != set(targets):
            raise ApiError("revision_conflict", 409)
        for camera_id, target in targets.items():
            observed = current[camera_id]
            if (observed.coreId, observed.homeId, observed.camera) != (
                decision.coreId, decision.homeId, target.camera
            ) or observed.observedAtMs > nowMs:
                raise ApiError("revision_conflict", 409)

        digest = self._digest(decision)
        old = self._receipts.get(requestId)
        if old is not None:
            if old[0] != digest:
                raise ApiError("idempotency_conflict", 409)
            return old[1]
        if len(self._receipts) >= self._max_batches:
            raise ApiError("invalid_request", 429)

        self._audit.ensure_capacity(2)
        self._audit.append(
            kind="command_batch", profileId=decision.profileId,
            profileRevision=decision.profileRevision, actorAccountId=authority.accountId,
            requestId=requestId, status="accepted", payloadHash=digest, atMs=nowMs,
        )
        results = []
        for camera_id in sorted(targets):
            target, observed = targets[camera_id], current[camera_id]
            command_id = hashlib.sha256(
                (requestId + camera_id + str(decision.profileRevision)).encode("ascii")
            ).hexdigest()[:32]
            if observed.mode == target.mode:
                results.append(CameraCommandResult(
                    schemaVersion=1, commandId=command_id, cameraId=camera_id,
                    status="skipped", code="already_applied", readback=None,
                ))
                continue
            command = CameraWorkerCommand(
                schemaVersion=1, commandId=command_id, requestId=requestId,
                coreId=decision.coreId, homeId=decision.homeId,
                profileId=decision.profileId, profileRevision=decision.profileRevision,
                actorAccountId=authority.accountId, camera=target.camera,
                expectedStateRevision=observed.stateRevision, desiredMode=target.mode,
            )
            try:
                raw_returned = worker(command)
            except Exception:
                results.append(CameraCommandResult(
                    schemaVersion=1, commandId=command_id, cameraId=camera_id,
                    status="unknown", code="worker_ack_unknown", readback=None,
                ))
                continue
            try:
                returned = WorkerReadback.model_validate(raw_returned)
            except ValueError:
                results.append(CameraCommandResult(
                    schemaVersion=1, commandId=command_id, cameraId=camera_id,
                    status="failed", code="worker_response_invalid", readback=None,
                ))
                continue
            exact = (
                returned.commandId == command.commandId
                and returned.camera == command.camera
                and returned.stateRevision > command.expectedStateRevision
                and returned.mode == command.desiredMode
                and returned.observedAtMs >= observed.observedAtMs
            )
            results.append(CameraCommandResult(
                schemaVersion=1, commandId=command_id, cameraId=camera_id,
                status="applied" if exact else "failed",
                code="applied" if exact else "readback_mismatch",
                readback=returned,
            ))
        statuses = {item.status for item in results}
        if statuses == {"skipped"}:
            status = "already_applied"
        elif statuses <= {"applied", "skipped"}:
            status = "applied"
        elif len(statuses) > 1:
            status = "partial"
        elif statuses == {"failed"}:
            status = "failed"
        else:
            status = "unknown"
        receipt = CameraCommandReceipt(
            schemaVersion=1, requestId=requestId, profileId=decision.profileId,
            profileRevision=decision.profileRevision, status=status,
            results=results, createdAtMs=nowMs,
        )
        receipt_hash = hashlib.sha256(
            json.dumps(receipt.model_dump(mode="json"), sort_keys=True,
                       separators=(",", ":")).encode()
        ).hexdigest()
        self._audit.append(
            kind="result", profileId=decision.profileId,
            profileRevision=decision.profileRevision, actorAccountId=authority.accountId,
            requestId=requestId, status=status, payloadHash=receipt_hash, atMs=nowMs,
        )
        self._receipts[requestId] = (digest, receipt)
        return receipt
