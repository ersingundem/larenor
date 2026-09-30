"""Preview/confirm valve boundary with readback and no implicit replay."""

import hashlib
import json
import secrets
import threading
from dataclasses import dataclass

from ..errors import ApiError
from .models import (
    IrrigationAuthority,
    IrrigationPlan,
    IrrigationPolicy,
    IrrigationPreview,
    IrrigationReceipt,
    IrrigationStopReceipt,
    IrrigationStopResult,
    ValveCommandResult,
    ValveReadback,
    ValveWorkerCommand,
    ValveStopCommand,
    WorkerValveReadback,
    WorkerValveStopReadback,
)

MAX_VALVE_READBACK_AGE_MS = 30_000


def _hash(value):
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


@dataclass(frozen=True)
class _StoredPreview:
    authority: IrrigationAuthority
    plan: IrrigationPlan
    readbacks: tuple[ValveReadback, ...]
    request_id: str
    token: str
    expires_at: int


class IrrigationCoordinator:
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
        self._resolve_plan = planResolver
        self._limit = maxReceipts
        self._previews, self._receipts = {}, {}
        self._stop_receipts = {}
        self._request_previews = {}
        self._lock = threading.Lock()

    def _live(self, authority, plan):
        try:
            authority = IrrigationAuthority.model_validate(authority)
            plan = IrrigationPlan.model_validate(plan)
        except ValueError:
            raise ApiError("invalid_request") from None
        try:
            try:
                resolved = self._resolve_authority(authority)
            except (TypeError, KeyError, AttributeError):
                resolved = self._resolve_authority(authority.accountId)
            if resolved is None:
                resolved = self._resolve_authority(authority.accountId)
            current_authority = IrrigationAuthority.model_validate(
                resolved
            )
            current_policy = IrrigationPolicy.model_validate(
                self._resolve_policy(plan.policyId)
            )
        except Exception:  # noqa: BLE001 -- external state must fail closed.
            raise ApiError("forbidden", 403) from None
        try:
            current_plan = IrrigationPlan.model_validate(
                self._resolve_plan(plan.planId)
            )
        except Exception:  # noqa: BLE001 -- external state must fail closed.
            raise ApiError("revision_conflict", 409) from None
        if current_authority != authority:
            raise ApiError("revision_conflict", 409)
        if (
            not authority.active
            or authority.role != "admin"
            or not authority.canManageIrrigation
        ):
            raise ApiError("forbidden", 403)
        if (
            (
                plan.coreId,
                plan.homeId,
                plan.homeRevision,
                plan.actorAccountId,
                plan.accountRevision,
                plan.sessionFamilyId,
            )
            != (
                authority.coreId,
                authority.homeId,
                authority.homeRevision,
                authority.accountId,
                authority.accountRevision,
                authority.sessionFamilyId,
            )
            or _hash(current_policy.model_dump(mode="json")) != plan.policyHash
            or current_plan != plan
        ):
            raise ApiError("revision_conflict", 409)
        return authority, plan, current_policy

    def preview(self, rawAuthority, rawPlan, rawReadbacks, *, requestId, nowMs):
        authority, plan, policy = self._live(rawAuthority, rawPlan)
        try:
            readbacks = tuple(
                ValveReadback.model_validate(item) for item in rawReadbacks
            )
            if (
                not isinstance(requestId, str)
                or len(requestId) != 32
                or any(char not in "0123456789abcdef" for char in requestId)
                or type(nowMs) is not int
                or nowMs < plan.generatedAtMs
            ):
                raise ValueError
        except ValueError:
            raise ApiError("invalid_request") from None
        planned = {
            item.zone.zoneId: item for item in plan.items if item.status == "planned"
        }
        observed = {item.zone.zoneId: item for item in readbacks}
        if (
            not planned
            or len(observed) != len(readbacks)
            or set(observed) != set(planned)
        ):
            raise ApiError("revision_conflict", 409)
        for zone_id, item in observed.items():
            if (
                (item.coreId, item.homeId, item.zone)
                != (plan.coreId, plan.homeId, planned[zone_id].zone)
                or item.observedAtMs > nowMs
                or nowMs - item.observedAtMs > MAX_VALVE_READBACK_AGE_MS
                or item.valveOpen
            ):
                raise ApiError("revision_conflict", 409)
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
                return IrrigationPreview(
                    schemaVersion=1,
                    previewId=old_id,
                    confirmToken=old.token,
                    requestId=old.request_id,
                    planId=old.plan.planId,
                    policyRevision=old.plan.policyRevision,
                    expiresAtMs=old.expires_at,
                    commandCount=sum(
                        item.status == "planned" for item in old.plan.items
                    ),
                )
            if len(self._previews) >= self._limit:
                raise ApiError("invalid_request", 429)
            preview_id, token = secrets.token_hex(16), secrets.token_urlsafe(32)
            expires = nowMs + policy.previewTtlMs
            stored = _StoredPreview(
                authority, plan, readbacks, requestId, token, expires
            )
            digest = _hash(plan.model_dump(mode="json"))
            self._audit.append(
                kind="preview",
                policyId=plan.policyId,
                policyRevision=plan.policyRevision,
                actorAccountId=authority.accountId,
                requestId=requestId,
                status="accepted",
                payloadHash=digest,
                atMs=nowMs,
            )
            self._previews[preview_id] = stored
            self._request_previews[requestId] = preview_id
            return IrrigationPreview(
                schemaVersion=1,
                previewId=preview_id,
                confirmToken=token,
                requestId=requestId,
                planId=plan.planId,
                policyRevision=plan.policyRevision,
                expiresAtMs=expires,
                commandCount=len(planned),
            )

    def confirm(
        self,
        rawAuthority,
        previewId,
        confirmToken,
        *,
        nowMs,
        worker,
        cancelled=lambda: False,
        stopWorker=None,
    ):
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
                or nowMs > stored.expires_at
                or nowMs < plan.generatedAtMs
            ):
                raise ApiError("invalid_request")
            self._audit.ensure_capacity(1)
            planned = {
                item.zone.zoneId: item
                for item in plan.items
                if item.status == "planned"
            }
            observed = {item.zone.zoneId: item for item in stored.readbacks}
            results = []

            def cancelled_result(command, item, before, result=None):
                stop_ok = False
                if stopWorker is not None:
                    stop_command = ValveStopCommand(
                        schemaVersion=1,
                        commandId=hashlib.sha256(
                            (command.commandId + "stop").encode("ascii")
                        ).hexdigest()[:32],
                        requestId=stored.request_id,
                        actorAccountId=authority.accountId,
                        zone=item.zone,
                        expectedStateRevision=max(
                            before.stateRevision,
                            before.stateRevision if result is None
                            else result.stateRevision,
                        ),
                    )
                    try:
                        stopped = WorkerValveStopReadback.model_validate(
                            stopWorker(stop_command)
                        )
                        stop_ok = (
                            stopped.commandId == stop_command.commandId
                            and stopped.zone == stop_command.zone
                            and stopped.stateRevision
                            > stop_command.expectedStateRevision
                            and not stopped.valveOpen
                            and not stopped.flowActive
                        )
                    except Exception:  # noqa: BLE001 -- fail closed.
                        stop_ok = False
                return ValveCommandResult(
                    schemaVersion=1,
                    commandId=command.commandId,
                    zoneId=item.zone.zoneId,
                    status="failed" if stop_ok else "unknown",
                    code="cancelled_safe_stop" if stop_ok else "safe_stop_failed",
                    readback=result,
                )

            for zone_id in sorted(planned):
                item, before = planned[zone_id], observed[zone_id]
                command_id = hashlib.sha256(
                    (stored.request_id + zone_id + plan.planId).encode("ascii")
                ).hexdigest()[:32]
                command = ValveWorkerCommand(
                    schemaVersion=1,
                    commandId=command_id,
                    requestId=stored.request_id,
                    planId=plan.planId,
                    policyRevision=plan.policyRevision,
                    actorAccountId=authority.accountId,
                    zone=item.zone,
                    expectedStateRevision=before.stateRevision,
                    durationSeconds=item.durationSeconds,
                    expectedWaterMl=item.estimatedWaterMl,
                )
                if cancelled():
                    results.append(
                        ValveCommandResult(
                            schemaVersion=1,
                            commandId=command_id,
                            zoneId=zone_id,
                            status="failed",
                            code="cancelled_before_start",
                            readback=None,
                        )
                    )
                    continue
                try:
                    raw_result = worker(command)
                except Exception:  # noqa: BLE001 -- external state must fail closed.
                    if cancelled():
                        results.append(cancelled_result(command, item, before))
                        continue
                    results.append(
                        ValveCommandResult(
                            schemaVersion=1,
                            commandId=command_id,
                            zoneId=zone_id,
                            status="unknown",
                            code="worker_ack_unknown",
                            readback=None,
                        )
                    )
                    continue
                try:
                    result = WorkerValveReadback.model_validate(raw_result)
                except ValueError:
                    results.append(
                        ValveCommandResult(
                            schemaVersion=1,
                            commandId=command_id,
                            zoneId=zone_id,
                            status="failed",
                            code="readback_mismatch",
                            readback=None,
                        )
                    )
                    continue
                if cancelled():
                    results.append(cancelled_result(command, item, before, result))
                    continue
                exact = (
                    result.commandId == command_id
                    and result.zone == command.zone
                    and result.stateRevision > before.stateRevision
                    and result.observedAtMs >= before.observedAtMs
                    and not result.valveOpen
                )
                flow = result.flowVerified and result.deliveredMl > 0
                bounded_flow = (
                    command.expectedWaterMl * 80 // 100
                    <= result.deliveredMl
                    <= command.expectedWaterMl * 110 // 100
                )
                code = (
                    "applied"
                    if exact and flow and bounded_flow
                    else (
                        "readback_mismatch"
                        if not exact
                        else "flow_not_verified"
                        if not flow
                        else "flow_out_of_bounds"
                    )
                )
                results.append(
                    ValveCommandResult(
                        schemaVersion=1,
                        commandId=command_id,
                        zoneId=zone_id,
                        status="applied" if code == "applied" else "failed",
                        code=code,
                        readback=result,
                    )
                )
            states = {item.status for item in results}
            status = (
                "applied"
                if states == {"applied"}
                else ("partial" if len(states) > 1 else next(iter(states)))
            )
            receipt = IrrigationReceipt(
                schemaVersion=1,
                requestId=stored.request_id,
                planId=plan.planId,
                status=status,
                results=results,
                completedAtMs=nowMs,
            )
            digest = _hash(receipt.model_dump(mode="json"))
            self._audit.append(
                kind="result",
                policyId=plan.policyId,
                policyRevision=plan.policyRevision,
                actorAccountId=authority.accountId,
                requestId=stored.request_id,
                status=status,
                payloadHash=digest,
                atMs=nowMs,
            )
            self._receipts[stored.request_id] = receipt
            return receipt

    def stop(
        self,
        rawAuthority,
        rawPolicy,
        rawReadbacks,
        zoneIds,
        *,
        requestId,
        nowMs,
        worker,
    ):
        authority = self._authority_only(rawAuthority)
        try:
            policy = IrrigationPolicy.model_validate(rawPolicy)
            current = IrrigationPolicy.model_validate(
                self._resolve_policy(policy.policyId)
            )
            readbacks = tuple(
                ValveReadback.model_validate(value) for value in rawReadbacks
            )
            if (
                current != policy
                or not policy.active
                or not isinstance(requestId, str)
                or len(requestId) != 32
                or any(value not in "0123456789abcdef" for value in requestId)
                or type(nowMs) is not int
                or nowMs < 0
            ):
                raise ValueError
        except (TypeError, ValueError):
            raise ApiError("revision_conflict", 409) from None
        zones = {item.zoneId: item for item in policy.zones}
        requested = tuple(sorted(zoneIds))
        fingerprint = _hash({
            "authority": authority.model_dump(mode="json"),
            "policy": policy.model_dump(mode="json"),
            "zones": requested,
        })
        observed = {item.zone.zoneId: item for item in readbacks}
        if (
            not requested
            or len(requested) != len(set(requested))
            or any(zone_id not in zones for zone_id in requested)
            or set(observed) != set(requested)
            or any(
                (item.coreId, item.homeId, item.zone)
                != (policy.coreId, policy.homeId, zones[zone_id])
                or item.observedAtMs > nowMs
                or nowMs - item.observedAtMs > MAX_VALVE_READBACK_AGE_MS
                for zone_id, item in observed.items()
            )
        ):
            raise ApiError("revision_conflict", 409)
        with self._lock:
            old = self._stop_receipts.get(requestId)
            if old is not None:
                if old[0] != fingerprint:
                    raise ApiError("idempotency_conflict", 409)
                return old[1]
            if len(self._stop_receipts) >= self._limit:
                raise ApiError("irrigation_stop_limit", 429)
            results = []
            for zone_id in requested:
                before = observed[zone_id]
                command_id = hashlib.sha256(
                    (requestId + zone_id + "stop").encode("ascii")
                ).hexdigest()[:32]
                command = ValveStopCommand(
                    schemaVersion=1,
                    commandId=command_id,
                    requestId=requestId,
                    actorAccountId=authority.accountId,
                    zone=zones[zone_id],
                    expectedStateRevision=before.stateRevision,
                )
                try:
                    readback = WorkerValveStopReadback.model_validate(worker(command))
                except Exception:  # noqa: BLE001 -- lost acknowledgement is unknown.
                    results.append(IrrigationStopResult(
                        schemaVersion=1, commandId=command_id, zoneId=zone_id,
                        status="unknown", code="worker_ack_unknown", readback=None,
                    ))
                    continue
                exact = (
                    readback.commandId == command.commandId
                    and readback.zone == command.zone
                    and readback.stateRevision > before.stateRevision
                    and readback.observedAtMs >= before.observedAtMs
                    and not readback.valveOpen
                )
                code = (
                    "readback_mismatch" if not exact
                    else "flow_still_active" if readback.flowActive
                    else "stopped"
                )
                results.append(IrrigationStopResult(
                    schemaVersion=1, commandId=command_id, zoneId=zone_id,
                    status="stopped" if code == "stopped" else "failed",
                    code=code, readback=readback,
                ))
            states = {item.status for item in results}
            status = (
                "stopped" if states == {"stopped"}
                else "partial" if len(states) > 1
                else next(iter(states))
            )
            receipt = IrrigationStopReceipt(
                schemaVersion=1, requestId=requestId, status=status,
                results=results, completedAtMs=nowMs,
            )
            self._audit.append(
                kind="stop", policyId=policy.policyId,
                policyRevision=policy.policyRevision,
                actorAccountId=authority.accountId, requestId=requestId,
                status=status,
                payloadHash=_hash(receipt.model_dump(mode="json")), atMs=nowMs,
            )
            self._stop_receipts[requestId] = (fingerprint, receipt)
            return receipt

    def _authority_only(self, rawAuthority):
        try:
            authority = IrrigationAuthority.model_validate(rawAuthority)
            try:
                resolved = self._resolve_authority(authority)
            except (TypeError, KeyError, AttributeError):
                resolved = self._resolve_authority(authority.accountId)
            if resolved is None:
                resolved = self._resolve_authority(authority.accountId)
            current = IrrigationAuthority.model_validate(resolved)
        except Exception:
            raise ApiError("forbidden", 403) from None
        if current != authority:
            raise ApiError("revision_conflict", 409)
        if (
            not authority.active
            or authority.role != "admin"
            or not authority.canManageIrrigation
        ):
            raise ApiError("forbidden", 403)
        return authority
