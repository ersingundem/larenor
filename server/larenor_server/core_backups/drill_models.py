from typing import Annotated, Literal

from pydantic import Field, StringConstraints, model_validator

from ..models import StrictModel


ObjectId = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{32}$")]
DrillState = Literal["queued", "running", "succeeded", "failed", "cancelled"]
DrillResource = Literal[
    "coreDatabase",
    "vaultKey",
    "configuration",
    "familyBoard",
    "componentData",
]


class CreateRecoveryDrillRequest(StrictModel):
    contractVersion: Literal[1]
    requestId: ObjectId
    mode: Literal["isolated_full_restore"]
    deadlineSeconds: Annotated[int, Field(ge=60, le=3600)]


class CancelRecoveryDrillRequest(StrictModel):
    expectedRevision: Annotated[int, Field(ge=1, le=2**63 - 2)]


class RecoveryDrillReceipt(StrictModel):
    contractVersion: Literal[1]
    outcome: Literal["succeeded", "failed", "cancelled"]
    effectPolicy: Literal["deny_all_production_effects"]
    startedAt: Annotated[int, Field(ge=0, le=253402300799)]
    completedAt: Annotated[int, Field(ge=0, le=253402300799)]
    durationMilliseconds: Annotated[int, Field(ge=0, le=3_600_000)]
    verifiedResources: list[DrillResource] = Field(max_length=5)
    failureCode: Literal[
        "deadline_exceeded",
        "authority_changed",
        "backup_failed",
        "restore_failed",
        "health_check_failed",
        "cancelled",
        "worker_unavailable",
    ] | None = None

    @model_validator(mode="after")
    def coherent_outcome(self):
        expected = [
            "coreDatabase",
            "vaultKey",
            "configuration",
            "familyBoard",
            "componentData",
        ]
        if self.verifiedResources != expected[: len(self.verifiedResources)]:
            raise ValueError("invalid_verified_resources")
        if (self.outcome == "succeeded") != (
            self.failureCode is None and self.verifiedResources == expected
        ):
            raise ValueError("invalid_drill_outcome")
        if self.completedAt < self.startedAt:
            raise ValueError("invalid_drill_duration")
        return self


class RecoveryDrill(StrictModel):
    id: ObjectId
    requestId: ObjectId
    contractVersion: Literal[1]
    mode: Literal["isolated_full_restore"]
    scope: list[DrillResource] = Field(min_length=5, max_length=5)
    deadlineSeconds: Annotated[int, Field(ge=60, le=3600)]
    revision: Annotated[int, Field(ge=1, le=2**63 - 2)]
    state: DrillState
    cancelRequested: bool
    createdAt: Annotated[int, Field(ge=0, le=253402300799)]
    updatedAt: Annotated[int, Field(ge=0, le=253402300799)]
    receipt: RecoveryDrillReceipt | None = None

    @model_validator(mode="after")
    def coherent_state(self):
        expected = [
            "coreDatabase",
            "vaultKey",
            "configuration",
            "familyBoard",
            "componentData",
        ]
        if self.scope != expected:
            raise ValueError("invalid_drill_scope")
        terminal = self.state in {"succeeded", "failed", "cancelled"}
        if terminal != (self.receipt is not None):
            raise ValueError("invalid_drill_receipt")
        if self.receipt is not None and self.receipt.outcome != self.state:
            raise ValueError("invalid_drill_receipt")
        return self


class RecoveryDrillResponse(StrictModel):
    drill: RecoveryDrill


class RecoveryDrillsResponse(StrictModel):
    drills: list[RecoveryDrill] = Field(max_length=20)
    nextBefore: Annotated[int, Field(ge=1, le=2**63 - 1)] | None
