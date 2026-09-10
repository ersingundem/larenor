"""Closed command-effect wire models; credentials never cross this boundary."""

import hashlib
import json
from typing import Annotated, Literal

from pydantic import Field

from ..home_resources.models import FrozenModel, Identity, Revision, Snapshot
from .models import Action, CommandRequest, TargetState
from .service import KeeneticEffectError, RESULT


def preview_receipt(request: CommandRequest) -> str:
    """Bind dispatch to the exact preview input without disclosing private text."""
    request = CommandRequest.model_validate(request)
    raw = json.dumps(
        request.model_dump(mode="json"),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    ).encode("ascii")
    return hashlib.sha256(b"larenor-keenetic-preview-v1\0" + raw).hexdigest()


class KeeneticWorkerCommand(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    action: Action
    target: TargetState
    expectedUserRevision: Revision
    previewReceipt: Snapshot
    timeoutMs: Annotated[int, Field(ge=50, le=10000)]

    @classmethod
    def from_request(cls, request: CommandRequest, *, timeout_ms: int):
        request = CommandRequest.model_validate(request)
        return cls(
            schemaVersion=1,
            requestId=request.requestId,
            action=request.action,
            target=request.target,
            expectedUserRevision=request.expectedUserRevision,
            previewReceipt=preview_receipt(request),
            timeoutMs=timeout_ms,
        )


class KeeneticWorkerResult(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    action: Action
    target: TargetState
    previewReceipt: Snapshot
    status: Literal["succeeded", "failed", "unknown"]
    code: Literal[
        "keenetic_effect_succeeded",
        "keenetic_effect_unavailable",
        "keenetic_effect_rejected",
        "keenetic_effect_cancelled",
        "keenetic_effect_timeout",
        "keenetic_effect_unknown",
        "keenetic_worker_restarted",
        "keenetic_result_unknown",
    ]
    observedState: TargetState | None

    @classmethod
    def for_command(cls, command: KeeneticWorkerCommand, value):
        command = KeeneticWorkerCommand.model_validate(command)
        result = cls.model_validate(value)
        if (
            result.requestId != command.requestId
            or result.action != command.action
            or result.target != command.target
            or result.previewReceipt != command.previewReceipt
        ):
            raise KeeneticEffectError("keenetic_result_unknown", uncertain=True)
        observed = result.observedState
        if result.status == "succeeded":
            if result.code != "keenetic_effect_succeeded" or observed is None:
                raise KeeneticEffectError("keenetic_result_unknown", uncertain=True)
            old = command.target
            if (
                observed.model_dump(exclude={"stateRevision", "value"})
                != old.model_dump(exclude={"stateRevision", "value"})
                or observed.stateRevision <= old.stateRevision
                or observed.value != RESULT[command.action]
            ):
                raise KeeneticEffectError("keenetic_result_unknown", uncertain=True)
        elif observed is not None or (
            result.status == "failed"
            and result.code not in {
                "keenetic_effect_unavailable",
                "keenetic_effect_rejected",
                "keenetic_effect_cancelled",
            }
        ) or (
            result.status == "unknown"
            and result.code not in {
                "keenetic_effect_timeout",
                "keenetic_effect_unknown",
                "keenetic_worker_restarted",
                "keenetic_result_unknown",
            }
        ):
            raise KeeneticEffectError("keenetic_result_unknown", uncertain=True)
        return result

    @classmethod
    def error_for_command(cls, command, code, *, uncertain):
        status = "unknown" if uncertain else "failed"
        return cls(
            schemaVersion=1,
            requestId=command.requestId,
            action=command.action,
            target=command.target,
            previewReceipt=command.previewReceipt,
            status=status,
            code=code,
            observedState=None,
        )
