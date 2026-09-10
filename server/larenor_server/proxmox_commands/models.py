from dataclasses import dataclass
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator


Identity = Annotated[str, Field(min_length=32, max_length=32, pattern=r"^[0-9a-f]{32}$")]
OpaqueIdentity = Annotated[str, Field(min_length=1, max_length=128, pattern=r"^[A-Za-z0-9_-]+$")]
Revision = Annotated[int, Field(ge=1, le=2**63 - 1)]
Action = Literal["start", "shutdown", "stop", "reboot", "suspend", "resume"]
State = Literal["accepted", "executing", "succeeded", "failed", "cancelled", "unknown"]


class StrictModel(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)


class PreviewRequest(StrictModel):
    schemaVersion: Literal[1]
    requestId: Identity
    action: Action
    expectedUserRevision: Revision
    expectedResourceRevision: Revision
    expectedAclRevision: Revision
    expectedBindingId: OpaqueIdentity
    expectedBindingRevision: Revision
    expectedServiceId: OpaqueIdentity
    expectedServiceRevision: Revision
    expectedGuestKind: Literal["qemu", "lxc"]
    expectedCurrentState: Literal["running", "stopped", "suspended", "unavailable"]
    expectedStatusRevision: Revision

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def exact_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class ConfirmRequest(StrictModel):
    schemaVersion: Literal[1]
    requestId: Identity
    highRiskConfirmed: bool
    deadlineMs: Annotated[int, Field(ge=500, le=30_000)]

    @field_validator("schemaVersion", "deadlineMs", mode="before")
    @classmethod
    def exact_int(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_integer")
        return value


class PowerPreview(StrictModel):
    schemaVersion: Literal[1] = 1
    id: Identity
    requestId: Identity
    action: Action
    riskClass: Literal["low", "moderate", "high"]
    requiresSecondConfirmation: bool
    guestKind: Literal["qemu", "lxc"]
    currentState: Literal["running", "stopped", "suspended"]
    expectedResultState: Literal["running", "stopped", "suspended"]
    expiresAt: float


class PowerReceipt(StrictModel):
    schemaVersion: Literal[1] = 1
    requestId: Identity
    action: Action
    state: State
    resultCode: Literal["accepted", "executing", "completed", "effect_failed", "cancelled", "outcome_uncertain"]
    guestState: Literal["running", "stopped", "suspended"]
    statusRevision: Revision
    causalityVerified: bool
    createdAt: float
    updatedAt: float


@dataclass(frozen=True)
class ProxmoxGuestDescriptor:
    resource_id: str
    binding_id: str
    binding_revision: int
    service_id: str
    service_revision: int
    guest_kind: str
    status: str
    status_revision: int


@dataclass(frozen=True)
class ProxmoxPowerEffectResult:
    outcome: str
    state: str
    status_revision: int
