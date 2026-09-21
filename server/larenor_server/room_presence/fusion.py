"""Deterministic, privacy-bounded room presence fusion and automation handoff."""

import hashlib
import json
import re

from ..errors import ApiError
from .models import (
    PresenceAuthority,
    PresenceAutomationCommand,
    PresenceHandoffReceipt,
    PresenceEstimate,
    PresencePolicy,
    PrivatePresenceSignal,
    WorkerPresenceReceipt,
)


_IDENTITY = re.compile(r"^[0-9a-f]{32}$")
_MAX_REVISION = 2**63 - 1


def _digest(value):
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


class RoomPresenceFusion:
    """Keeps hysteresis counters, never raw identifiers or observation history."""

    def __init__(
        self,
        *,
        authorityResolver,
        policyResolver,
        maxSourceCheckpoints=256,
    ):
        if (
            type(maxSourceCheckpoints) is not int
            or not 1 <= maxSourceCheckpoints <= 4096
        ):
            raise ValueError("invalid_source_checkpoint_limit")
        self._resolve_authority = authorityResolver
        self._resolve_policy = policyResolver
        self._max_source_checkpoints = maxSourceCheckpoints
        self._bound_scope = None
        self._current_room = None
        self._candidate_room = None
        self._candidate_count = 0
        self._exit_count = 0
        self._transition_revision = 0
        self._last_observations = {}

    @property
    def private_history_size(self):
        return 0

    def snapshot_state(self):
        """Return only reduced replay/fusion state; raw observations never persist."""
        return {
            "schemaVersion": 1,
            "boundScope": list(self._bound_scope) if self._bound_scope else None,
            "currentRoom": self._current_room,
            "candidateRoom": self._candidate_room,
            "candidateCount": self._candidate_count,
            "exitCount": self._exit_count,
            "transitionRevision": self._transition_revision,
            "observationCheckpoints": dict(self._last_observations),
        }

    def restore_state(self, raw):
        if (
            not isinstance(raw, dict)
            or set(raw)
            != {
                "schemaVersion",
                "boundScope",
                "currentRoom",
                "candidateRoom",
                "candidateCount",
                "exitCount",
                "transitionRevision",
                "observationCheckpoints",
            }
            or raw["schemaVersion"] != 1
        ):
            raise ValueError("invalid_presence_fusion_state")
        scope = raw["boundScope"]
        if scope is not None and (
            not isinstance(scope, list)
            or len(scope) != 11
            or any(not isinstance(item, (str, int)) for item in scope)
        ):
            raise ValueError("invalid_presence_fusion_state")
        rooms = (raw["currentRoom"], raw["candidateRoom"])
        if any(
            value is not None
            and (not isinstance(value, str) or _IDENTITY.fullmatch(value) is None)
            for value in rooms
        ):
            raise ValueError("invalid_presence_fusion_state")
        numbers = (
            raw["candidateCount"],
            raw["exitCount"],
            raw["transitionRevision"],
        )
        if any(
            type(value) is not int or not 0 <= value <= _MAX_REVISION
            for value in numbers
        ):
            raise ValueError("invalid_presence_fusion_state")
        checkpoints = raw["observationCheckpoints"]
        if (
            not isinstance(checkpoints, dict)
            or len(checkpoints) > self._max_source_checkpoints
            or any(
                not isinstance(key, str)
                or re.fullmatch(r"[0-9a-f]{64}", key) is None
                or type(value) is not int
                or not 1 <= value <= _MAX_REVISION
                for key, value in checkpoints.items()
            )
        ):
            raise ValueError("invalid_presence_fusion_state")
        self._bound_scope = tuple(scope) if scope is not None else None
        self._current_room, self._candidate_room = rooms
        self._candidate_count, self._exit_count, self._transition_revision = numbers
        self._last_observations = dict(checkpoints)

    def _authority(self, raw):
        try:
            value = PresenceAuthority.model_validate(raw)
            current = PresenceAuthority.model_validate(
                self._resolve_authority(value.accountId)
            )
        except Exception:
            raise ApiError("forbidden", 403) from None
        if current != value:
            raise ApiError("revision_conflict", 409)
        if not value.active or not value.canReadPresence:
            raise ApiError("forbidden", 403)
        return value

    def _policy(self, raw):
        try:
            value = PresencePolicy.model_validate(raw)
            current = PresencePolicy.model_validate(
                self._resolve_policy(value.policyId)
            )
        except ValueError:
            raise ApiError("invalid_request") from None
        except Exception:
            raise ApiError("revision_conflict", 409) from None
        if current != value:
            raise ApiError("revision_conflict", 409)
        if not value.active:
            raise ApiError("forbidden", 403)
        if not value.device.consentActive:
            raise ApiError("consent_required", 403)
        return value

    def fuse(self, rawAuthority, rawPolicy, rawSignals, *, nowMs):
        authority, policy = self._authority(rawAuthority), self._policy(rawPolicy)
        if (authority.coreId, authority.homeId, authority.homeRevision) != (
            policy.coreId,
            policy.homeId,
            policy.homeRevision,
        ):
            raise ApiError("not_found", 404)
        if type(nowMs) is not int or nowMs < 0 or not isinstance(rawSignals, list):
            raise ApiError("invalid_request")
        if not 1 <= len(rawSignals) <= 64:
            raise ApiError("invalid_request")
        try:
            signals = [
                PrivatePresenceSignal.model_validate(item) for item in rawSignals
            ]
        except ValueError:
            raise ApiError("invalid_request") from None

        rooms = {room.roomId: room for room in policy.rooms}
        sources = {source.sourceId: source for source in policy.sources}
        seen = set()
        exact_scope = (
            policy.coreId,
            policy.homeId,
            policy.homeRevision,
            policy.policyId,
            policy.policyRevision,
            policy.device.deviceId,
            policy.device.deviceRevision,
            policy.device.modelId,
            policy.device.modelRevision,
            policy.device.consentId,
            policy.device.consentRevision,
        )
        if self._bound_scope is not None and self._bound_scope != exact_scope:
            raise ApiError("scope_mismatch", 409)
        for signal in signals:
            room = rooms.get(signal.roomId)
            source = sources.get(signal.sourceId)
            if room is None or source is None:
                raise ApiError("not_found", 404)
            exact = (
                signal.coreId,
                signal.homeId,
                signal.homeRevision,
                signal.roomRevision,
                signal.deviceId,
                signal.deviceRevision,
                signal.modelId,
                signal.modelRevision,
                signal.policyId,
                signal.policyRevision,
                signal.consentId,
                signal.consentRevision,
            )
            expected = (
                policy.coreId,
                policy.homeId,
                policy.homeRevision,
                room.roomRevision,
                policy.device.deviceId,
                policy.device.deviceRevision,
                policy.device.modelId,
                policy.device.modelRevision,
                policy.policyId,
                policy.policyRevision,
                policy.device.consentId,
                policy.device.consentRevision,
            )
            if exact != expected:
                raise ApiError("revision_conflict", 409)
            if (signal.sourceKind, signal.sourceRevision) != (
                source.sourceKind,
                source.sourceRevision,
            ):
                raise ApiError("revision_conflict", 409)
            source_key = _digest(
                {
                    "sourceId": signal.sourceId,
                    "sourceKind": signal.sourceKind,
                    "rawIdentifier": signal.rawIdentifier,
                }
            )
            if source_key in seen:
                raise ApiError("invalid_request")
            seen.add(source_key)
            previous = self._last_observations.get(source_key, 0)
            if signal.observationRevision <= previous:
                raise ApiError("revision_conflict", 409)

        new_checkpoints = seen.difference(self._last_observations)
        if (
            len(self._last_observations) + len(new_checkpoints)
            > self._max_source_checkpoints
        ):
            raise ApiError("source_checkpoint_limit", 409)

        # Validate the whole batch before advancing replay checkpoints.
        self._bound_scope = exact_scope
        for signal in signals:
            source_key = _digest(
                {
                    "sourceId": signal.sourceId,
                    "sourceKind": signal.sourceKind,
                    "rawIdentifier": signal.rawIdentifier,
                }
            )
            self._last_observations[source_key] = signal.observationRevision
        fresh = [
            signal
            for signal in signals
            if signal.observedAtMs <= nowMs
            and nowMs - signal.observedAtMs <= policy.maxSignalAgeMs
        ]
        if not fresh:
            self._clear_presence()
            return self._estimate(authority, policy, "unknown", None, 0, 0, nowMs)

        by_room = {}
        for signal in fresh:
            current = by_room.get(signal.roomId)
            if current is None or (
                signal.confidencePermille,
                signal.observedAtMs,
                signal.observationRevision,
            ) > (
                current.confidencePermille,
                current.observedAtMs,
                current.observationRevision,
            ):
                by_room[signal.roomId] = signal
        best = max(
            by_room.values(),
            key=lambda item: (
                item.confidencePermille,
                item.observedAtMs,
                item.roomId,
            ),
        )
        observed_at = max(signal.observedAtMs for signal in fresh)

        if self._current_room is None:
            if best.confidencePermille < policy.enterConfidencePermille:
                self._candidate_room, self._candidate_count = None, 0
                return self._estimate(
                    authority, policy, "unknown", None, 0, 0, observed_at
                )
            self._advance_candidate(best.roomId)
            if self._candidate_count < policy.enterObservations:
                return self._estimate(
                    authority,
                    policy,
                    "candidate",
                    None,
                    best.confidencePermille,
                    len(fresh),
                    observed_at,
                )
            self._current_room = best.roomId
            self._candidate_room, self._candidate_count, self._exit_count = None, 0, 0
            self._transition_revision += 1
            return self._estimate(
                authority,
                policy,
                "present",
                best,
                best.confidencePermille,
                len(fresh),
                observed_at,
            )

        current = by_room.get(self._current_room)
        current_confidence = current.confidencePermille if current else 0
        if best.roomId != self._current_room and (
            best.confidencePermille >= policy.enterConfidencePermille
        ):
            self._advance_candidate(best.roomId)
            if self._candidate_count >= policy.enterObservations:
                self._current_room = best.roomId
                self._candidate_room, self._candidate_count, self._exit_count = (
                    None,
                    0,
                    0,
                )
                self._transition_revision += 1
                return self._estimate(
                    authority,
                    policy,
                    "present",
                    best,
                    best.confidencePermille,
                    len(fresh),
                    observed_at,
                )
            current_room = rooms[self._current_room]
            return self._estimate(
                authority,
                policy,
                "uncertain",
                current_room,
                current_confidence,
                len(fresh),
                observed_at,
            )

        self._candidate_room, self._candidate_count = None, 0
        if current_confidence < policy.exitConfidencePermille:
            self._exit_count += 1
            if self._exit_count >= policy.exitObservations:
                self._clear_presence()
                return self._estimate(
                    authority, policy, "unknown", None, 0, 0, observed_at
                )
            return self._estimate(
                authority,
                policy,
                "uncertain",
                rooms[self._current_room],
                current_confidence,
                len(fresh),
                observed_at,
            )
        self._exit_count = 0
        return self._estimate(
            authority,
            policy,
            "present",
            current,
            current_confidence,
            len(fresh),
            observed_at,
        )

    def _advance_candidate(self, room_id):
        if self._candidate_room == room_id:
            self._candidate_count += 1
        else:
            self._candidate_room, self._candidate_count = room_id, 1

    def _clear_presence(self):
        self._current_room = self._candidate_room = None
        self._candidate_count = self._exit_count = 0

    def _estimate(
        self, authority, policy, status, room, confidence, samples, observed_at
    ):
        room_id = getattr(room, "roomId", None)
        room_revision = getattr(room, "roomRevision", None)
        identity = {
            "home": policy.homeId,
            "device": policy.device.deviceId,
            "policyRevision": policy.policyRevision,
            "consentRevision": policy.device.consentRevision,
            "status": status,
            "roomId": room_id,
            "roomRevision": room_revision,
            "confidence": confidence,
            "observedAt": observed_at,
            "samples": samples,
            "transition": self._transition_revision,
        }
        return PresenceEstimate(
            schemaVersion=1,
            estimateId=_digest(identity)[:32],
            coreId=policy.coreId,
            homeId=policy.homeId,
            homeRevision=policy.homeRevision,
            deviceId=policy.device.deviceId,
            deviceRevision=policy.device.deviceRevision,
            modelId=policy.device.modelId,
            modelRevision=policy.device.modelRevision,
            policyId=policy.policyId,
            policyRevision=policy.policyRevision,
            consentId=policy.device.consentId,
            consentRevision=policy.device.consentRevision,
            status=status,
            roomId=room_id,
            roomRevision=room_revision,
            confidencePermille=confidence,
            observedAtMs=observed_at,
            sampleCount=samples,
            transitionRevision=self._transition_revision,
            advisoryOnly=True,
            grantsAccess=False,
        )


class PresenceAutomationHandoff:
    def __init__(
        self,
        *,
        authorityResolver,
        policyResolver,
        estimateResolver,
        maxReceipts=256,
    ):
        if type(maxReceipts) is not int or not 1 <= maxReceipts <= 4096:
            raise ValueError("invalid_receipt_limit")
        self._resolve_authority = authorityResolver
        self._resolve_policy = policyResolver
        self._resolve_estimate = estimateResolver
        self._max_receipts = maxReceipts
        self._receipts = {}

    def dispatch(
        self,
        rawAuthority,
        rawPolicy,
        rawEstimate,
        *,
        automationId,
        automationRevision,
        requestId,
        worker,
    ):
        try:
            authority = PresenceAuthority.model_validate(rawAuthority)
            policy = PresencePolicy.model_validate(rawPolicy)
            estimate = PresenceEstimate.model_validate(rawEstimate)
            current_authority = PresenceAuthority.model_validate(
                self._resolve_authority(authority.accountId)
            )
            current_policy = PresencePolicy.model_validate(
                self._resolve_policy(policy.policyId)
            )
            current_estimate = PresenceEstimate.model_validate(
                self._resolve_estimate(estimate.estimateId)
            )
        except Exception:
            raise ApiError("revision_conflict", 409) from None
        if (
            authority != current_authority
            or policy != current_policy
            or estimate != current_estimate
        ):
            raise ApiError("revision_conflict", 409)
        if not authority.active or not authority.canManagePresence:
            raise ApiError("forbidden", 403)
        if (authority.coreId, authority.homeId, authority.homeRevision) != (
            policy.coreId,
            policy.homeId,
            policy.homeRevision,
        ) or (estimate.coreId, estimate.homeId) != (policy.coreId, policy.homeId):
            raise ApiError("not_found", 404)
        if (
            not policy.active
            or not policy.device.consentActive
            or not policy.device.allowAutomationHandoff
            or estimate.status != "present"
            or estimate.roomId is None
            or estimate.roomRevision is None
        ):
            raise ApiError("forbidden", 403)
        rooms = {room.roomId: room for room in policy.rooms}
        room = rooms.get(estimate.roomId)
        if room is None or (
            estimate.homeRevision,
            estimate.deviceId,
            estimate.deviceRevision,
            estimate.modelId,
            estimate.modelRevision,
            estimate.policyId,
            estimate.policyRevision,
            estimate.consentId,
            estimate.consentRevision,
            estimate.roomRevision,
        ) != (
            policy.homeRevision,
            policy.device.deviceId,
            policy.device.deviceRevision,
            policy.device.modelId,
            policy.device.modelRevision,
            policy.policyId,
            policy.policyRevision,
            policy.device.consentId,
            policy.device.consentRevision,
            room.roomRevision,
        ):
            raise ApiError("revision_conflict", 409)
        if (
            type(requestId) is not str
            or _IDENTITY.fullmatch(requestId) is None
            or type(automationId) is not str
            or _IDENTITY.fullmatch(automationId) is None
            or type(automationRevision) is not int
            or not 1 <= automationRevision <= _MAX_REVISION
        ):
            raise ApiError("invalid_request")
        command_id = _digest(
            {
                "requestId": requestId,
                "estimateId": estimate.estimateId,
                "automationId": automationId,
                "automationRevision": automationRevision,
            }
        )[:32]
        try:
            command = PresenceAutomationCommand(
                schemaVersion=1,
                commandId=command_id,
                requestId=requestId,
                automationId=automationId,
                automationRevision=automationRevision,
                estimateId=estimate.estimateId,
                transitionRevision=estimate.transitionRevision,
                deviceId=estimate.deviceId,
                deviceRevision=estimate.deviceRevision,
                modelRevision=estimate.modelRevision,
                policyRevision=estimate.policyRevision,
                consentRevision=estimate.consentRevision,
                roomId=estimate.roomId,
                roomRevision=estimate.roomRevision,
                advisoryOnly=True,
                grantsAccess=False,
            )
        except ValueError:
            raise ApiError("invalid_request") from None
        fingerprint = _digest(command.model_dump(mode="json"))
        stored = self._receipts.get(requestId)
        if stored is not None:
            if stored[0] != fingerprint:
                raise ApiError("idempotency_conflict", 409)
            return stored[1]
        if len(self._receipts) >= self._max_receipts:
            raise ApiError("receipt_limit", 409)

        readback = None
        try:
            readback = WorkerPresenceReceipt.model_validate(worker(command))
        except Exception:
            pass
        exact = readback is not None and (
            readback.commandId,
            readback.requestId,
            readback.automationId,
            readback.automationRevision,
            readback.estimateId,
            readback.transitionRevision,
            readback.deviceId,
            readback.roomId,
        ) == (
            command.commandId,
            command.requestId,
            command.automationId,
            command.automationRevision,
            command.estimateId,
            command.transitionRevision,
            command.deviceId,
            command.roomId,
        )
        if not exact:
            status, verified, revision = "unknown", False, None
        elif readback.accepted and readback.observedState == "present":
            status, verified, revision = "verified", True, readback.readbackRevision
        elif not readback.accepted and readback.observedState == "rejected":
            status, verified, revision = "rejected", False, readback.readbackRevision
        else:
            status, verified, revision = "unknown", False, None
        receipt = PresenceHandoffReceipt(
            schemaVersion=1,
            requestId=command.requestId,
            commandId=command.commandId,
            automationId=command.automationId,
            automationRevision=command.automationRevision,
            estimateId=command.estimateId,
            transitionRevision=command.transitionRevision,
            status=status,
            verified=verified,
            readbackRevision=revision,
        )
        self._receipts[requestId] = (fingerprint, receipt)
        return receipt
