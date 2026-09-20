from dataclasses import dataclass
import re
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from ..home_resources.models import ResourceRef


Identity = Annotated[str, Field(min_length=32, max_length=32, pattern=r"^[0-9a-f]{32}$")]
OpaqueIdentity = Annotated[str, Field(min_length=1, max_length=128, pattern=r"^[A-Za-z0-9_-]+$")]
Revision = Annotated[int, Field(ge=1, le=2**63 - 1)]
Action = Literal["start", "shutdown", "stop", "reboot", "reset", "suspend", "resume"]
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
    userRevision: Revision = 1
    resourceRevision: Revision = 1
    aclRevision: Revision = 1
    bindingRevision: Revision = 1
    serviceRevision: Revision = 1
    operationRef: str | None = None
    causalityVerified: bool
    createdAt: float
    updatedAt: float

    @field_validator("operationRef")
    @classmethod
    def safe_operation_ref(cls, value):
        if value is not None and not re.fullmatch(r"UPID-SHA256:[0-9a-f]{64}", value):
            raise ValueError("invalid_operation_ref")
        return value


class PowerJournalEvent(StrictModel):
    schemaVersion: Literal[1] = 1
    sequence: Revision
    eventKind: Literal["previewed", "preview_cancelled", "command_status"]
    requestId: Identity
    action: Action
    state: Literal["previewed", "preview_cancelled", "accepted", "executing", "succeeded", "failed", "cancelled", "unknown"]
    resultCode: Literal["preview_created", "preview_cancelled", "accepted", "executing", "completed", "effect_failed", "cancelled", "outcome_uncertain"]
    userRevision: Revision
    resourceRevision: Revision
    aclRevision: Revision
    bindingRevision: Revision
    serviceRevision: Revision
    statusRevision: Revision
    operationRef: str | None
    emittedAt: float


class PowerCommandAttribution(StrictModel):
    schemaVersion: Literal[1] = 1
    correlationId: Identity
    actorId: Identity
    source: Literal["core_api", "core_recovery", "unknown"]
    reason: Literal[
        "explicit_admin_preview",
        "explicit_admin_cancel",
        "explicit_admin_confirmation",
        "interrupted_after_restart",
        "unknown",
    ]
    serviceId: OpaqueIdentity | None
    serviceRevision: Revision | None

    @model_validator(mode="after")
    def closed_origin(self):
        allowed = {
            "core_api": {
                "explicit_admin_preview",
                "explicit_admin_cancel",
                "explicit_admin_confirmation",
            },
            "core_recovery": {"interrupted_after_restart"},
            "unknown": {"unknown"},
        }
        if self.reason not in allowed[self.source]:
            raise ValueError("attribution_mismatch")
        if (self.serviceId is None) != (self.serviceRevision is None):
            raise ValueError("service_mismatch")
        if self.source != "unknown" and self.serviceId is None:
            raise ValueError("service_required")
        return self


class AttributedPowerJournalEvent(PowerJournalEvent):
    attribution: PowerCommandAttribution

    @model_validator(mode="after")
    def trace_matches_event(self):
        if self.attribution.correlationId != self.requestId:
            raise ValueError("trace_mismatch")
        if (
            self.attribution.serviceRevision is not None
            and self.attribution.serviceRevision != self.serviceRevision
        ):
            raise ValueError("service_mismatch")
        return self


class AttributedPowerJournal(StrictModel):
    schemaVersion: Literal[1] = 1
    ref: ResourceRef
    entries: list[AttributedPowerJournalEvent] = Field(max_length=50)
    verified: Literal[True]


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
    installation_id: str | None = None
    node: str | None = None
    guest_id: int | None = None
    capability_ready: bool = False


@dataclass(frozen=True)
class ProxmoxPowerEffectResult:
    outcome: str
    state: str
    status_revision: int
    operation_ref: str | None = None
