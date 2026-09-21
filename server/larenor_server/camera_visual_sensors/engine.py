"""Revision-bound visual sensor reducer with explicit degraded state."""

from dataclasses import dataclass
import hashlib
import hmac
import json
import threading
from typing import Callable

from ..errors import ApiError
from .models import (
    CameraVisualAuthority,
    DetectionBatch,
    VisualSensorReading,
    VisualSensorRule,
)


MAX_RECEIPTS = 4_096
MAX_EVENTS = 8_192


def _canonical(value) -> bytes:
    if hasattr(value, "model_dump"):
        value = value.model_dump(mode="json")
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


@dataclass
class _RuleState:
    state: str = "off"
    sequence: int = 0
    last_captured_at: int = -1
    last_capture_revision: int = 0
    on_since: int | None = None
    off_since: int | None = None
    last_reading: VisualSensorReading | None = None


class VisualSensorEngine:
    """Accepts metadata only; raw frames, boxes, embeddings and secrets are absent."""

    def __init__(
        self,
        *,
        authorityResolver: Callable[[str], CameraVisualAuthority | None],
        ruleResolver: Callable[[str], VisualSensorRule | None],
        auditKey: bytes,
    ):
        if not isinstance(auditKey, bytes) or len(auditKey) < 32:
            raise ValueError("invalid_audit_key")
        self._resolve_authority = authorityResolver
        self._resolve_rule = ruleResolver
        self._audit_key = auditKey
        self._states: dict[str, _RuleState] = {}
        self._receipts: dict[str, tuple[str, VisualSensorReading]] = {}
        self._events: list[dict] = []
        self._lock = threading.RLock()

    @property
    def eventCount(self) -> int:
        with self._lock:
            return len(self._events)

    def _authority(self, presented: CameraVisualAuthority) -> CameraVisualAuthority:
        try:
            authority = CameraVisualAuthority.model_validate(presented)
            current = self._resolve_authority(authority.accountId)
        except Exception:
            raise ApiError("forbidden", 403) from None
        if current is None:
            raise ApiError("forbidden", 403)
        try:
            current = CameraVisualAuthority.model_validate(current)
        except ValueError:
            raise ApiError("forbidden", 403) from None
        if current != authority:
            raise ApiError("revision_conflict", 409)
        if (
            not authority.active
            or not authority.canManageVisualSensors
            or authority.role != "admin"
        ):
            raise ApiError("forbidden", 403)
        return authority

    def _rule(self, presented: VisualSensorRule) -> VisualSensorRule:
        try:
            sensor_rule = VisualSensorRule.model_validate(presented)
            current = self._resolve_rule(sensor_rule.ruleId)
        except Exception:
            raise ApiError("not_found", 404) from None
        if current is None:
            raise ApiError("not_found", 404)
        try:
            current = VisualSensorRule.model_validate(current)
        except ValueError:
            raise ApiError("not_found", 404) from None
        if current != sensor_rule:
            raise ApiError("revision_conflict", 409)
        if not sensor_rule.enabled:
            raise ApiError("forbidden", 403)
        return sensor_rule

    @staticmethod
    def _fingerprint(rule: VisualSensorRule, batch: DetectionBatch) -> str:
        return hashlib.sha256(
            _canonical(
                {
                    "rule": rule.model_dump(mode="json"),
                    "batch": batch.model_dump(mode="json"),
                }
            )
        ).hexdigest()

    def _append_event(
        self,
        *,
        authority: CameraVisualAuthority,
        batch: DetectionBatch,
        reading: VisualSensorReading,
        request_fingerprint: str,
    ) -> None:
        if len(self._events) >= MAX_EVENTS:
            raise ApiError("bounded_visual_sensor_limit_reached", 409)
        previous = self._events[-1]["signature"] if self._events else "0" * 64
        public = {
            "sequence": len(self._events) + 1,
            "coreId": authority.coreId,
            "homeId": authority.homeId,
            "accountId": authority.accountId,
            "ruleId": reading.ruleId,
            "ruleRevision": reading.ruleRevision,
            "cameraId": reading.cameraId,
            "captureRevision": batch.captureRevision,
            "requestFingerprint": request_fingerprint,
            "state": reading.state,
            "status": reading.status,
            "transition": reading.transition,
            "observedAtMs": reading.observedAtMs,
            "evidenceDigest": reading.evidenceDigest,
            "previous": previous,
        }
        signature = hmac.new(
            self._audit_key, _canonical(public), hashlib.sha256
        ).hexdigest()
        self._events.append({**public, "signature": signature})

    def ingest(
        self,
        presentedAuthority: CameraVisualAuthority,
        presentedRule: VisualSensorRule,
        rawBatch: DetectionBatch,
    ) -> VisualSensorReading:
        authority = self._authority(presentedAuthority)
        rule = self._rule(presentedRule)
        try:
            batch = DetectionBatch.model_validate(rawBatch)
        except ValueError:
            raise ApiError("invalid_request") from None
        if rule.cameraId not in authority.accessibleCameraIds:
            raise ApiError("not_found", 404)
        if batch.cameraId not in authority.accessibleCameraIds:
            raise ApiError("not_found", 404)
        if (
            batch.coreId != authority.coreId
            or batch.homeId != authority.homeId
            or batch.homeRevision != authority.homeRevision
            or batch.cameraId != rule.cameraId
            or batch.pipelineId != rule.pipelineId
            or batch.pipelineRevision != rule.pipelineRevision
            or batch.modelId != rule.modelId
            or batch.modelRevision != rule.modelRevision
        ):
            raise ApiError("revision_conflict", 409)
        if (
            batch.evidence.expiresAtMs < batch.capturedAtMs
            or batch.evidence.expiresAtMs - batch.capturedAtMs
            > rule.evidenceRetentionMs
        ):
            raise ApiError("invalid_request")

        fingerprint = self._fingerprint(rule, batch)
        with self._lock:
            prior = self._receipts.get(batch.requestId)
            if prior is not None:
                if prior[0] != fingerprint:
                    raise ApiError("idempotency_conflict", 409)
                return prior[1]
            if len(self._receipts) >= MAX_RECEIPTS:
                raise ApiError("bounded_visual_sensor_limit_reached", 409)
            state = self._states.setdefault(rule.ruleId, _RuleState())
            if (
                batch.capturedAtMs <= state.last_captured_at
                or batch.captureRevision <= state.last_capture_revision
            ):
                raise ApiError("revision_conflict", 409)

            confidence = 0
            count = 0
            for item in batch.detections:
                if item.label == rule.label and item.confidenceBps > confidence:
                    confidence = item.confidenceBps
                    count = item.count
            present = confidence >= rule.minimumConfidenceBps
            automation = False
            if batch.providerStatus == "degraded":
                # A degraded interval breaks continuous hysteresis evidence.
                # Preserve the last verified state internally, but require a
                # fresh ready interval before any later transition.
                state.on_since = None
                state.off_since = None
                output_state = "unknown"
                transition = "provider_degraded"
            elif state.state == "off" and present:
                state.off_since = None
                if state.on_since is None:
                    state.on_since = batch.capturedAtMs
                if batch.capturedAtMs - state.on_since >= rule.holdForMs:
                    state.state = "on"
                    state.on_since = None
                    transition = "activated"
                    automation = True
                else:
                    transition = "holding_on"
                output_state = state.state
            elif state.state == "on" and not present:
                state.on_since = None
                if state.off_since is None:
                    state.off_since = batch.capturedAtMs
                if batch.capturedAtMs - state.off_since >= rule.clearAfterMs:
                    state.state = "off"
                    state.off_since = None
                    transition = "cleared"
                    automation = True
                else:
                    transition = "holding_off"
                output_state = state.state
            else:
                state.on_since = None if not present else state.on_since
                state.off_since = None if present else state.off_since
                transition = "stable_on" if state.state == "on" else "stable_off"
                output_state = state.state

            state.sequence += 1
            reading = VisualSensorReading(
                schemaVersion=1,
                ruleId=rule.ruleId,
                ruleRevision=rule.ruleRevision,
                cameraId=rule.cameraId,
                state=output_state,
                status=batch.providerStatus,
                transition=transition,
                automationEligible=automation,
                sequence=state.sequence,
                observedAtMs=batch.capturedAtMs,
                captureRevision=batch.captureRevision,
                evidenceDigest=batch.evidence.digest,
                confidenceBps=confidence,
                count=count,
            )
            self._append_event(
                authority=authority,
                batch=batch,
                reading=reading,
                request_fingerprint=fingerprint,
            )
            state.last_captured_at = batch.capturedAtMs
            state.last_capture_revision = batch.captureRevision
            state.last_reading = reading
            self._receipts[batch.requestId] = (fingerprint, reading)
            return reading

    def export(self, presentedAuthority: CameraVisualAuthority, ruleId: str) -> dict:
        authority = self._authority(presentedAuthority)
        with self._lock:
            state = self._states.get(ruleId)
            if state is None or state.last_reading is None:
                raise ApiError("not_found", 404)
            reading = state.last_reading
            if reading.cameraId not in authority.accessibleCameraIds:
                raise ApiError("not_found", 404)
            return {
                "schemaVersion": 1,
                "ruleId": reading.ruleId,
                "ruleRevision": reading.ruleRevision,
                "cameraId": reading.cameraId,
                "state": reading.state,
                "status": reading.status,
                "transition": reading.transition,
                "automationEligible": reading.automationEligible,
                "sequence": reading.sequence,
                "observedAtMs": reading.observedAtMs,
                "captureRevision": reading.captureRevision,
                "evidenceDigest": reading.evidenceDigest,
                "confidenceBps": reading.confidenceBps,
                "count": reading.count,
            }

    def verifyAudit(self) -> bool:
        with self._lock:
            previous = "0" * 64
            for stored in self._events:
                public = {
                    key: value for key, value in stored.items() if key != "signature"
                }
                if public.get("previous") != previous:
                    return False
                expected = hmac.new(
                    self._audit_key,
                    _canonical(public),
                    hashlib.sha256,
                ).hexdigest()
                if not hmac.compare_digest(stored.get("signature", ""), expected):
                    return False
                previous = expected
            return True
