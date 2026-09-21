"""Preview/confirm boundary for HVAC and window device effects."""

from dataclasses import dataclass
import hashlib
import json
import secrets
import threading

from ..errors import ApiError
from .models import (
    ComfortAuthority,
    ComfortCommandResult,
    ComfortDeviceReadback,
    ComfortPlan,
    ComfortPolicy,
    ComfortPreview,
    ComfortReceipt,
    ComfortWorkerCommand,
    WorkerComfortReadback,
)
from .planner import digest


@dataclass(frozen=True)
class _StoredPreview:
    authority: ComfortAuthority
    plan: ComfortPlan
    readbacks: tuple[ComfortDeviceReadback, ...]
    request_id: str
    token: str
    expires_at: int


class ComfortCoordinator:
    def __init__(
        self,
        *,
        audit,
        authorityResolver,
        policyResolver,
        planResolver,
        maxReceipts=1024,
    ):
        if type(maxReceipts) is not int or not 1 <= maxReceipts <= 4096:
            raise ValueError("invalid_receipt_limit")
        self._audit = audit
        self._resolve_authority, self._resolve_policy = (
            authorityResolver,
            policyResolver,
        )
        self._resolve_plan, self._limit = planResolver, maxReceipts
        self._previews, self._request_previews, self._receipts = {}, {}, {}
        self._lock = threading.Lock()

    def _live(self, rawAuthority, rawPlan):
        try:
            authority = ComfortAuthority.model_validate(rawAuthority)
            plan = ComfortPlan.model_validate(rawPlan)
        except ValueError:
            raise ApiError("invalid_request") from None
        try:
            current_authority = ComfortAuthority.model_validate(
                self._resolve_authority(authority.accountId)
            )
            policy = ComfortPolicy.model_validate(self._resolve_policy(plan.policyId))
            stored_plan = ComfortPlan.model_validate(self._resolve_plan(plan.planId))
        except Exception:
            raise ApiError("forbidden", 403) from None
        if current_authority != authority or stored_plan != plan:
            raise ApiError("revision_conflict", 409)
        if (
            not authority.active
            or authority.role != "admin"
            or not authority.canManageComfort
        ):
            raise ApiError("forbidden", 403)
        if (
            plan.coreId,
            plan.homeId,
            plan.homeRevision,
            plan.actorAccountId,
            plan.accountRevision,
            plan.sessionFamilyId,
        ) != (
            authority.coreId,
            authority.homeId,
            authority.homeRevision,
            authority.accountId,
            authority.accountRevision,
            authority.sessionFamilyId,
        ) or digest(policy.model_dump(mode="json")) != plan.policyHash:
            raise ApiError("revision_conflict", 409)
        return authority, plan, policy

    @staticmethod
    def _commands(plan, readbacks):
        desired = {}
        for item in plan.items:
            desired[(item.room.roomId, "hvac")] = (item.room.hvac, item.hvacMode)
            desired[(item.room.roomId, "window")] = (item.room.window, item.windowState)
        observed = {(item.roomId, item.device.kind): item for item in readbacks}
        if len(observed) != len(readbacks) or set(observed) != set(desired):
            raise ApiError("revision_conflict", 409)
        for key, value in observed.items():
            if (value.coreId, value.homeId, value.roomId, value.device) != (
                plan.coreId,
                plan.homeId,
                key[0],
                desired[key][0],
            ):
                raise ApiError("revision_conflict", 409)
        return [
            (key, desired[key], observed[key])
            for key in sorted(desired)
            if desired[key][1] != observed[key].state
        ]

    def preview(self, rawAuthority, rawPlan, rawReadbacks, *, requestId, nowMs):
        authority, plan, policy = self._live(rawAuthority, rawPlan)
        try:
            readbacks = tuple(
                ComfortDeviceReadback.model_validate(item) for item in rawReadbacks
            )
            if (
                not isinstance(requestId, str)
                or len(requestId) != 32
                or any(char not in "0123456789abcdef" for char in requestId)
                or type(nowMs) is not int
                or nowMs < plan.generatedAtMs
                or any(item.observedAtMs > nowMs for item in readbacks)
            ):
                raise ValueError
        except ValueError:
            raise ApiError("invalid_request") from None
        commands = self._commands(plan, readbacks)
        if not commands:
            raise ApiError("invalid_request")
        with self._lock:
            old_id = self._request_previews.get(requestId)
            if old_id is not None:
                old = self._previews[old_id]
                if (old.authority, old.plan, old.readbacks) != (
                    authority,
                    plan,
                    readbacks,
                ):
                    raise ApiError("idempotency_conflict", 409)
                return ComfortPreview(
                    schemaVersion=1,
                    previewId=old_id,
                    confirmToken=old.token,
                    requestId=requestId,
                    planId=plan.planId,
                    expiresAtMs=old.expires_at,
                    commandCount=len(commands),
                )
            if len(self._previews) >= self._limit:
                raise ApiError("invalid_request", 429)
            preview_id, token = secrets.token_hex(16), secrets.token_urlsafe(32)
            stored = _StoredPreview(
                authority,
                plan,
                readbacks,
                requestId,
                token,
                nowMs + policy.previewTtlMs,
            )
            self._audit.append(
                kind="preview",
                policyId=plan.policyId,
                policyRevision=plan.policyRevision,
                actorAccountId=authority.accountId,
                requestId=requestId,
                status="accepted",
                payloadHash=digest(plan.model_dump(mode="json")),
                atMs=nowMs,
            )
            self._previews[preview_id] = stored
            self._request_previews[requestId] = preview_id
            return ComfortPreview(
                schemaVersion=1,
                previewId=preview_id,
                confirmToken=token,
                requestId=requestId,
                planId=plan.planId,
                expiresAtMs=stored.expires_at,
                commandCount=len(commands),
            )

    def confirm(self, rawAuthority, previewId, confirmToken, *, nowMs, worker):
        with self._lock:
            stored = self._previews.get(previewId)
            if (
                stored is None
                or not isinstance(confirmToken, str)
                or not secrets.compare_digest(stored.token, confirmToken)
            ):
                raise ApiError("invalid_request")
            authority, plan, _policy = self._live(rawAuthority, stored.plan)
            old = self._receipts.get(stored.request_id)
            if old is not None:
                return old
            if (
                type(nowMs) is not int
                or nowMs < plan.generatedAtMs
                or nowMs > stored.expires_at
            ):
                raise ApiError("invalid_request")
            commands = self._commands(plan, stored.readbacks)
            self._audit.ensure_capacity(1)
            results = []
            for (room_id, kind), (device, desired_state), before in commands:
                command_id = hashlib.sha256(
                    (stored.request_id + room_id + kind + plan.planId).encode("ascii")
                ).hexdigest()[:32]
                command = ComfortWorkerCommand(
                    schemaVersion=1,
                    commandId=command_id,
                    requestId=stored.request_id,
                    planId=plan.planId,
                    policyRevision=plan.policyRevision,
                    actorAccountId=authority.accountId,
                    roomId=room_id,
                    targetKind=kind,
                    device=device,
                    expectedStateRevision=before.stateRevision,
                    desiredState=desired_state,
                )
                try:
                    raw_result = worker(command)
                except Exception:
                    results.append(
                        ComfortCommandResult(
                            schemaVersion=1,
                            commandId=command_id,
                            roomId=room_id,
                            targetKind=kind,
                            status="unknown",
                            code="worker_ack_unknown",
                            readback=None,
                        )
                    )
                    continue
                try:
                    value = WorkerComfortReadback.model_validate(raw_result)
                except ValueError:
                    results.append(
                        ComfortCommandResult(
                            schemaVersion=1,
                            commandId=command_id,
                            roomId=room_id,
                            targetKind=kind,
                            status="failed",
                            code="readback_mismatch",
                            readback=None,
                        )
                    )
                    continue
                exact = (
                    value.commandId == command_id
                    and value.roomId == room_id
                    and value.device == device
                    and value.stateRevision > before.stateRevision
                    and value.state == desired_state
                    and value.observedAtMs >= before.observedAtMs
                )
                results.append(
                    ComfortCommandResult(
                        schemaVersion=1,
                        commandId=command_id,
                        roomId=room_id,
                        targetKind=kind,
                        status="applied" if exact else "failed",
                        code="applied" if exact else "readback_mismatch",
                        readback=value,
                    )
                )
            states = {item.status for item in results}
            status = (
                "applied"
                if states == {"applied"}
                else ("partial" if len(states) > 1 else next(iter(states)))
            )
            receipt = ComfortReceipt(
                schemaVersion=1,
                requestId=stored.request_id,
                planId=plan.planId,
                status=status,
                results=results,
                completedAtMs=nowMs,
            )
            self._audit.append(
                kind="result",
                policyId=plan.policyId,
                policyRevision=plan.policyRevision,
                actorAccountId=authority.accountId,
                requestId=stored.request_id,
                status=status,
                payloadHash=digest(receipt.model_dump(mode="json")),
                atMs=nowMs,
            )
            self._receipts[stored.request_id] = receipt
            return receipt
