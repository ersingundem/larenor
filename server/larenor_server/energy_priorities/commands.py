"""Explicit inverter preview-confirm authority with exact readback."""

from dataclasses import dataclass
import hashlib
import hmac
import json
import secrets
import threading
from typing import Callable

from ..errors import ApiError
from .models import (
    EnergyAuthority,
    EnergyPlan,
    InverterCommand,
    InverterCommandPreview,
    InverterCommandResult,
    InverterReadback,
)


MAX_COMMANDS = 1_000
MAX_AUDIT = 10_000
ZERO_HASH = "0" * 64


@dataclass(frozen=True)
class EnergyCommandAuditEntry:
    sequence: int
    action: str
    requestId: str
    planId: str
    coreId: str
    homeId: str
    accountId: str
    sessionFamilyId: str
    inverterId: str
    inputDigest: str
    targetPowerW: int
    createdAtMs: int
    previousHash: str
    entryHash: str


@dataclass
class _CommandState:
    preview: InverterCommandPreview
    plan: EnergyPlan
    result: InverterCommandResult | None = None


class InverterCommandManager:
    def __init__(
        self,
        *,
        auditKey: bytes,
        authorityResolver: Callable[[str], EnergyAuthority | None],
        planResolver: Callable[[str], EnergyPlan | None],
        worker: Callable[[InverterCommand], InverterReadback],
        clockMs: Callable[[], int],
    ):
        if not isinstance(auditKey, bytes) or len(auditKey) < 32:
            raise ValueError("invalid_audit_key")
        self._key = auditKey
        self._resolve_authority = authorityResolver
        self._resolve_plan = planResolver
        self._worker = worker
        self._clock = clockMs
        self._commands: dict[str, _CommandState] = {}
        self._audit: list[EnergyCommandAuditEntry] = []
        self._lock = threading.RLock()

    @property
    def audit(self):
        with self._lock:
            self._validate_audit()
            return tuple(self._audit)

    def _authority(self, presented):
        try:
            authority = EnergyAuthority.model_validate(presented)
            current = self._resolve_authority(authority.accountId)
            current = None if current is None else EnergyAuthority.model_validate(current)
        except Exception:
            raise ApiError("forbidden", 403) from None
        if current is None:
            raise ApiError("forbidden", 403)
        if current != authority:
            raise ApiError("revision_conflict", 409)
        if not authority.active or not authority.canControl or authority.role != "admin":
            raise ApiError("forbidden", 403)
        return authority

    def _entry_hash(self, values):
        raw = json.dumps(values, separators=(",", ":")).encode("ascii")
        return hmac.new(
            self._key,
            b"larenor:energy-command-audit:v1\0" + raw,
            hashlib.sha256,
        ).hexdigest()

    def _validate_audit(self):
        if len(self._audit) > MAX_AUDIT:
            raise ApiError("energy_command_integrity_failed", 503)
        previous = ZERO_HASH
        for sequence, entry in enumerate(self._audit, 1):
            expected = self._entry_hash(
                [
                    sequence,
                    entry.action,
                    entry.requestId,
                    entry.planId,
                    entry.coreId,
                    entry.homeId,
                    entry.accountId,
                    entry.sessionFamilyId,
                    entry.inverterId,
                    entry.inputDigest,
                    entry.targetPowerW,
                    entry.createdAtMs,
                    previous,
                ]
            )
            if (
                entry.sequence != sequence
                or entry.action not in {"previewed", "confirmed", "uncertain"}
                or entry.previousHash != previous
                or not secrets.compare_digest(entry.entryHash, expected)
            ):
                raise ApiError("energy_command_integrity_failed", 503)
            previous = entry.entryHash

    def _append_audit(self, action, preview):
        self._validate_audit()
        if len(self._audit) >= MAX_AUDIT:
            raise ApiError("energy_command_integrity_failed", 503)
        sequence = len(self._audit) + 1
        previous = self._audit[-1].entryHash if self._audit else ZERO_HASH
        created = self._clock()
        values = [
            sequence,
            action,
            preview.requestId,
            preview.planId,
            preview.coreId,
            preview.homeId,
            preview.accountId,
            preview.sessionFamilyId,
            preview.inverterId,
            preview.inputDigest,
            preview.targetPowerW,
            created,
            previous,
        ]
        self._audit.append(
            EnergyCommandAuditEntry(
                sequence=sequence,
                action=action,
                requestId=preview.requestId,
                planId=preview.planId,
                coreId=preview.coreId,
                homeId=preview.homeId,
                accountId=preview.accountId,
                sessionFamilyId=preview.sessionFamilyId,
                inverterId=preview.inverterId,
                inputDigest=preview.inputDigest,
                targetPowerW=preview.targetPowerW,
                createdAtMs=created,
                previousHash=previous,
                entryHash=self._entry_hash(values),
            )
        )

    def _token(self, values):
        raw = json.dumps(values, separators=(",", ":")).encode("ascii")
        return hmac.new(
            self._key,
            b"larenor:energy-confirmation:v1\0" + raw,
            hashlib.sha256,
        ).hexdigest()

    @staticmethod
    def _preview_values(preview):
        return [
            preview.requestId,
            preview.planId,
            preview.coreId,
            preview.homeId,
            preview.accountId,
            preview.accountRevision,
            preview.memberRevision,
            preview.sessionFamilyId,
            preview.inverterId,
            preview.expectedInverterRevision,
            preview.batteryId,
            preview.expectedBatteryRevision,
            preview.inputDigest,
            preview.targetPowerW,
            preview.expiresAtMs,
        ]

    def _current_plan(self, plan):
        try:
            current = self._resolve_plan(plan.planId)
            current = None if current is None else EnergyPlan.model_validate(current)
        except Exception:
            raise ApiError("revision_conflict", 409) from None
        if current != plan:
            raise ApiError("revision_conflict", 409)
        if (
            plan.overrideStatus == "active"
            and plan.overrideExpiresAtMs is not None
            and self._clock() >= plan.overrideExpiresAtMs
        ):
            raise ApiError("revision_conflict", 409)

    def preview(
        self,
        presentedAuthority,
        rawPlan,
        *,
        slotIndex,
        requestId,
        inverterId,
        expectedInverterRevision,
    ):
        authority = self._authority(presentedAuthority)
        try:
            plan = EnergyPlan.model_validate(rawPlan)
            if type(slotIndex) is not int or not 0 <= slotIndex < len(plan.slots):
                raise ValueError
            if plan.coreId != authority.coreId or plan.homeId != authority.homeId:
                raise ValueError
            self._current_plan(plan)
            slot = plan.slots[slotIndex]
            signed_power = slot.powerW if slot.action == "charge" else -slot.powerW
            expires = self._clock() + 60_000
            draft = InverterCommandPreview(
                schemaVersion=1,
                requestId=requestId,
                planId=plan.planId,
                coreId=plan.coreId,
                homeId=plan.homeId,
                accountId=authority.accountId,
                accountRevision=authority.accountRevision,
                memberRevision=authority.memberRevision,
                sessionFamilyId=authority.sessionFamilyId,
                inverterId=inverterId,
                expectedInverterRevision=expectedInverterRevision,
                batteryId=plan.batteryId,
                expectedBatteryRevision=plan.batteryRevision,
                inputDigest=plan.inputDigest,
                targetPowerW=signed_power,
                expiresAtMs=expires,
                confirmationToken=ZERO_HASH,
            )
            preview = draft.model_copy(
                update={"confirmationToken": self._token(self._preview_values(draft))}
            )
        except ApiError:
            raise
        except Exception:
            raise ApiError("invalid_request") from None
        with self._lock:
            self._validate_audit()
            prior = self._commands.get(preview.requestId)
            if prior is not None:
                if prior.preview != preview:
                    raise ApiError("invalid_request")
                return prior.preview
            if len(self._commands) >= MAX_COMMANDS:
                raise ApiError("revision_conflict", 409)
            self._commands[preview.requestId] = _CommandState(preview, plan)
            self._append_audit("previewed", preview)
            return preview

    def confirm(self, presentedAuthority, rawPreview, confirmationToken):
        authority = self._authority(presentedAuthority)
        try:
            preview = InverterCommandPreview.model_validate(rawPreview)
        except ValueError:
            raise ApiError("invalid_request") from None
        with self._lock:
            self._validate_audit()
            state = self._commands.get(preview.requestId)
            expected_token = self._token(self._preview_values(preview))
            if (
                state is None
                or state.preview != preview
                or (
                    preview.coreId,
                    preview.homeId,
                    preview.accountId,
                    preview.accountRevision,
                    preview.memberRevision,
                    preview.sessionFamilyId,
                )
                != (
                    authority.coreId,
                    authority.homeId,
                    authority.accountId,
                    authority.accountRevision,
                    authority.memberRevision,
                    authority.sessionFamilyId,
                )
                or not isinstance(confirmationToken, str)
                or not secrets.compare_digest(confirmationToken, expected_token)
            ):
                raise ApiError("invalid_request")
            if state.result is not None:
                return state.result
            if self._clock() >= preview.expiresAtMs:
                raise ApiError("invalid_request")
            self._current_plan(state.plan)
            command = InverterCommand(
                schemaVersion=1,
                requestId=preview.requestId,
                planId=preview.planId,
                coreId=preview.coreId,
                homeId=preview.homeId,
                accountId=preview.accountId,
                accountRevision=preview.accountRevision,
                memberRevision=preview.memberRevision,
                sessionFamilyId=preview.sessionFamilyId,
                inverterId=preview.inverterId,
                expectedInverterRevision=preview.expectedInverterRevision,
                batteryId=preview.batteryId,
                expectedBatteryRevision=preview.expectedBatteryRevision,
                inputDigest=preview.inputDigest,
                targetPowerW=preview.targetPowerW,
            )
            try:
                readback = InverterReadback.model_validate(self._worker(command))
            except Exception:
                readback = None
            expected = InverterReadback(
                schemaVersion=1,
                requestId=command.requestId,
                coreId=command.coreId,
                homeId=command.homeId,
                inverterId=command.inverterId,
                inverterRevision=command.expectedInverterRevision,
                batteryId=command.batteryId,
                batteryRevision=command.expectedBatteryRevision,
                inputDigest=command.inputDigest,
                targetPowerW=command.targetPowerW,
                observedPowerW=command.targetPowerW,
                status="applied",
            )
            if readback == expected:
                result = InverterCommandResult(
                    schemaVersion=1,
                    requestId=command.requestId,
                    status="confirmed",
                    reason=None,
                    readbackVerified=True,
                    readback=readback,
                )
                action = "confirmed"
            else:
                result = InverterCommandResult(
                    schemaVersion=1,
                    requestId=command.requestId,
                    status="uncertain",
                    reason="lost_ack" if readback is None else "readback_mismatch",
                    readbackVerified=False,
                    readback=None,
                )
                action = "uncertain"
            state.result = result
            self._append_audit(action, preview)
            return result
