"""Bounded local sound-event reducer with a tamper-evident handoff journal."""

from dataclasses import dataclass
import hashlib
import hmac
import json
import secrets
import threading
import uuid
from typing import Callable

from ..errors import ApiError
from .models import (
    AutomationReceipt,
    AutomationSoundTrigger,
    SoundClassifierBinding,
    SoundEvent,
    SoundEventAuthority,
    SoundIngestResult,
    SoundObservation,
)


MAX_EVENTS = 10_000
MAX_AUDIT = 10_000
MAX_OBSERVATIONS = 20_000
ZERO_HASH = "0" * 64


@dataclass(frozen=True)
class SoundAuditEntry:
    sequence: int
    action: str
    observationId: str
    eventId: str
    deviceId: str
    modelRevision: int
    policyRevision: int
    consentRevision: int
    createdAtMs: int
    previousHash: str
    entryHash: str


@dataclass
class _DetectorState:
    last_observed_ms: int = -1
    consecutive: int = 0
    active: bool = False
    last_event_ms: int | None = None


class SoundEventEngine:
    """No audio bytes, paths, URLs, credentials or free-form evidence are stored."""

    def __init__(
        self,
        *,
        auditKey: bytes,
        authorityResolver: Callable[[str], SoundEventAuthority | None],
        bindingResolver: Callable[[str], SoundClassifierBinding | None],
        automationHandoff: Callable[[AutomationSoundTrigger], AutomationReceipt] | None,
        clockMs: Callable[[], int],
    ):
        if not isinstance(auditKey, bytes) or len(auditKey) < 32:
            raise ValueError("invalid_audit_key")
        self._audit_key = auditKey
        self._resolve_authority = authorityResolver
        self._resolve_binding = bindingResolver
        self._handoff = automationHandoff
        self._clock = clockMs
        self._events: list[SoundEvent] = []
        self._audit: list[SoundAuditEntry] = []
        self._detectors: dict[tuple, _DetectorState] = {}
        self._observations: dict[str, tuple[SoundObservation, SoundIngestResult]] = {}
        self._lock = threading.RLock()

    @property
    def audit(self) -> tuple[SoundAuditEntry, ...]:
        with self._lock:
            self._validate_audit()
            return tuple(self._audit)

    def _authority(self, presented) -> SoundEventAuthority:
        try:
            authority = SoundEventAuthority.model_validate(presented)
            current = self._resolve_authority(authority.accountId)
            current = (
                None if current is None else SoundEventAuthority.model_validate(current)
            )
        except Exception:
            raise ApiError("forbidden", 403) from None
        if current is None:
            raise ApiError("forbidden", 403)
        if current != authority:
            raise ApiError("revision_conflict", 409)
        if not authority.active or not authority.canObserve:
            raise ApiError("forbidden", 403)
        return authority

    @staticmethod
    def _binding_tuple(value):
        return (
            value.coreId,
            value.homeId,
            value.roomId,
            value.roomRevision,
            value.deviceId,
            value.deviceRevision,
            value.modelId,
            value.modelRevision,
            value.providerRevision,
            value.policyRevision,
            value.consentRevision,
        )

    def _binding(self, authority, observation):
        if (
            observation.coreId != authority.coreId
            or observation.homeId != authority.homeId
            or observation.roomId not in authority.accessibleRoomIds
            or observation.deviceId not in authority.accessibleDeviceIds
        ):
            raise ApiError("not_found", 404)
        try:
            binding = self._resolve_binding(observation.deviceId)
            binding = (
                None
                if binding is None
                else SoundClassifierBinding.model_validate(binding)
            )
        except Exception:
            return None
        if binding is None:
            return None
        if self._binding_tuple(binding) != self._binding_tuple(observation):
            raise ApiError("revision_conflict", 409)
        if not binding.consentGranted:
            raise ApiError("forbidden", 403)
        return binding

    def _entry_hash(self, values):
        payload = json.dumps(values, separators=(",", ":"), allow_nan=False).encode(
            "ascii"
        )
        return hmac.new(
            self._audit_key,
            b"larenor:sound-event-audit:v1\0" + payload,
            hashlib.sha256,
        ).hexdigest()

    def _validate_audit(self):
        if len(self._audit) > MAX_AUDIT:
            raise ApiError("sound_event_integrity_failed", 503)
        previous = ZERO_HASH
        for sequence, row in enumerate(self._audit, 1):
            values = [
                sequence,
                row.action,
                row.observationId,
                row.eventId,
                row.deviceId,
                row.modelRevision,
                row.policyRevision,
                row.consentRevision,
                row.createdAtMs,
                previous,
            ]
            expected = self._entry_hash(values)
            if (
                row.sequence != sequence
                or row.action
                not in {
                    "suppressed",
                    "provider_degraded",
                    "detected",
                    "handoff_verified",
                    "handoff_rejected",
                }
                or row.previousHash != previous
                or not secrets.compare_digest(row.entryHash, expected)
            ):
                raise ApiError("sound_event_integrity_failed", 503)
            previous = row.entryHash

    def _append_audit(self, action, observation, event_id=ZERO_HASH[:32]):
        self._validate_audit()
        if len(self._audit) >= MAX_AUDIT:
            raise ApiError("sound_event_integrity_failed", 503)
        sequence = len(self._audit) + 1
        previous = self._audit[-1].entryHash if self._audit else ZERO_HASH
        created = self._clock()
        values = [
            sequence,
            action,
            observation.observationId,
            event_id,
            observation.deviceId,
            observation.modelRevision,
            observation.policyRevision,
            observation.consentRevision,
            created,
            previous,
        ]
        entry = SoundAuditEntry(
            sequence=sequence,
            action=action,
            observationId=observation.observationId,
            eventId=event_id,
            deviceId=observation.deviceId,
            modelRevision=observation.modelRevision,
            policyRevision=observation.policyRevision,
            consentRevision=observation.consentRevision,
            createdAtMs=created,
            previousHash=previous,
            entryHash=self._entry_hash(values),
        )
        self._audit.append(entry)
        return entry

    @staticmethod
    def _suppressed(reason):
        return SoundIngestResult(
            schemaVersion=1,
            status="suppressed",
            reason=reason,
            event=None,
            automationVerified=False,
        )

    @staticmethod
    def _degraded(reason, event=None):
        return SoundIngestResult(
            schemaVersion=1,
            status="degraded",
            reason=reason,
            event=event,
            automationVerified=False,
        )

    def _remember(self, observation, result):
        if len(self._observations) >= MAX_OBSERVATIONS:
            oldest = next(iter(self._observations))
            self._observations.pop(oldest)
        self._observations[observation.observationId] = (observation, result)
        return result

    def _purge(self):
        now = self._clock()
        self._events = [
            event for event in self._events if event.retentionExpiresAtMs > now
        ]

    def ingest(self, presentedAuthority, rawObservation) -> SoundIngestResult:
        authority = self._authority(presentedAuthority)
        try:
            observation = SoundObservation.model_validate(rawObservation)
        except ValueError:
            raise ApiError("invalid_request") from None
        with self._lock:
            self._validate_audit()
            replay = self._observations.get(observation.observationId)
            if replay is not None:
                if replay[0] != observation:
                    raise ApiError("invalid_request")
                return replay[1]
            binding = self._binding(authority, observation)
            if binding is None or binding.providerStatus == "degraded":
                self._append_audit("provider_degraded", observation)
                return self._remember(
                    observation, self._degraded("provider_unavailable")
                )

            key = self._binding_tuple(binding) + (observation.className,)
            state = self._detectors.setdefault(key, _DetectorState())
            if observation.observedAtMs <= state.last_observed_ms:
                raise ApiError("invalid_request")
            state.last_observed_ms = observation.observedAtMs
            if observation.confidence <= binding.releaseConfidence:
                state.active = False
                state.consecutive = 0
                reason = "below_threshold"
            elif observation.confidence < binding.triggerConfidence:
                state.consecutive = 0
                reason = "below_threshold"
            elif state.active:
                reason = "hysteresis_active"
            else:
                state.consecutive += 1
                if state.consecutive < binding.consecutiveTriggerCount:
                    reason = "awaiting_confirmation"
                else:
                    state.active = True
                    state.consecutive = 0
                    if (
                        state.last_event_ms is not None
                        and observation.observedAtMs - state.last_event_ms
                        < binding.dedupWindowMs
                    ):
                        reason = "deduplicated"
                    else:
                        reason = None
            if reason is not None:
                self._append_audit("suppressed", observation)
                return self._remember(observation, self._suppressed(reason))

            event_id = uuid.uuid4().hex
            detected = self._append_audit("detected", observation, event_id)
            expires = observation.observedAtMs + binding.retentionSeconds * 1_000
            event_values = dict(
                schemaVersion=1,
                eventId=event_id,
                coreId=observation.coreId,
                homeId=observation.homeId,
                roomId=observation.roomId,
                roomRevision=observation.roomRevision,
                deviceId=observation.deviceId,
                deviceRevision=observation.deviceRevision,
                modelId=observation.modelId,
                modelRevision=observation.modelRevision,
                providerRevision=observation.providerRevision,
                policyRevision=observation.policyRevision,
                consentRevision=observation.consentRevision,
                className=observation.className,
                confidence=observation.confidence,
                observedAtMs=observation.observedAtMs,
                evidenceDigest=observation.evidenceDigest,
                retentionExpiresAtMs=expires,
            )
            trigger = AutomationSoundTrigger(
                **{
                    key: value
                    for key, value in event_values.items()
                    if key != "retentionExpiresAtMs"
                },
                auditSequence=detected.sequence,
                auditHead=detected.entryHash,
            )
            receipt = None
            if self._handoff is not None:
                try:
                    receipt = AutomationReceipt.model_validate(self._handoff(trigger))
                except Exception:
                    receipt = None
            expected = AutomationReceipt(
                schemaVersion=1,
                eventId=event_id,
                coreId=observation.coreId,
                homeId=observation.homeId,
                roomRevision=observation.roomRevision,
                deviceRevision=observation.deviceRevision,
                modelRevision=observation.modelRevision,
                providerRevision=observation.providerRevision,
                policyRevision=observation.policyRevision,
                consentRevision=observation.consentRevision,
                auditSequence=detected.sequence,
                auditHead=detected.entryHash,
                accepted=True,
            )
            verified = receipt == expected
            event = SoundEvent(**event_values, automationVerified=verified)
            self._purge()
            if len(self._events) >= MAX_EVENTS:
                self._events.pop(0)
            self._events.append(event)
            state.last_event_ms = observation.observedAtMs
            self._append_audit(
                "handoff_verified" if verified else "handoff_rejected",
                observation,
                event_id,
            )
            if verified:
                result = SoundIngestResult(
                    schemaVersion=1,
                    status="event",
                    reason=None,
                    event=event,
                    automationVerified=True,
                )
            else:
                result = self._degraded(
                    "automation_unavailable"
                    if self._handoff is None
                    else "automation_unverified",
                    event,
                )
            return self._remember(observation, result)

    def events(self, presentedAuthority) -> tuple[SoundEvent, ...]:
        authority = self._authority(presentedAuthority)
        with self._lock:
            self._validate_audit()
            self._purge()
            return tuple(
                event
                for event in self._events
                if event.coreId == authority.coreId
                and event.homeId == authority.homeId
                and event.roomId in authority.accessibleRoomIds
                and event.deviceId in authority.accessibleDeviceIds
            )
