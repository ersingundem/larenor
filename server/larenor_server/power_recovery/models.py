import hashlib
from typing import Annotated, Literal

from pydantic import Field, StringConstraints, field_validator, model_validator

from ..models import StrictModel


Identity = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{32}$")]
SafeName = Annotated[
    str, StringConstraints(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9_.:-]+$")
]
Timestamp = Annotated[int, Field(ge=0, le=253402300799)]
Revision = Annotated[int, Field(ge=1, le=2**63 - 1)]
OpaqueRef = Annotated[
    str, StringConstraints(min_length=1, max_length=128, pattern=r"^[A-Za-z0-9_-]+$")
]
ProviderNode = Annotated[
    str,
    StringConstraints(
        min_length=1,
        max_length=64,
        pattern=r"^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,62}[A-Za-z0-9])?$",
    ),
]


class ProxmoxPowerProviderRef(StrictModel):
    """Durable exact authority and provider selector captured at policy save."""

    contractVersion: Literal[1]
    provider: Literal["proxmox"]
    actorId: Identity
    actorRevision: Revision
    coreId: Identity
    homeId: Identity
    resourceId: Identity
    resourceRevision: Revision
    aclRevision: Revision
    bindingId: OpaqueRef
    bindingRevision: Revision
    serviceId: OpaqueRef
    serviceRevision: Revision
    egressRevision: Revision
    installationId: OpaqueRef
    node: ProviderNode
    guestKind: Literal["qemu", "lxc"]
    guestId: Annotated[int, Field(ge=1, le=999_999_999)]
    statusRevision: Revision

    def target_id(self) -> str:
        public_identity = (
            f"larenor-proxmox-target-v1:{self.installationId}:"
            f"{self.resourceId}:{self.node}:{self.guestKind}:{self.guestId}"
        )
        return hashlib.sha256(public_identity.encode("ascii")).hexdigest()[:32]


class PowerTarget(StrictModel):
    targetId: Identity
    label: Annotated[str, StringConstraints(min_length=1, max_length=80)]
    kind: Literal["service", "proxmoxGuest", "networkDevice", "coreHost"]
    shutdownOrder: Annotated[int, Field(ge=1, le=1000)]
    startOnRestore: bool
    timeoutSeconds: Annotated[int, Field(ge=5, le=300)]
    providerRef: ProxmoxPowerProviderRef | None = None

    @field_validator("label")
    @classmethod
    def safe_label(cls, value: str) -> str:
        if value != value.strip() or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid_power_target_label")
        return value

    @model_validator(mode="after")
    def coherent_provider_ref(self):
        if self.providerRef is not None and (
            self.kind != "proxmoxGuest"
            or self.targetId != self.providerRef.target_id()
        ):
            raise ValueError("invalid_power_target_provider_ref")
        return self


class ConfigurePowerRecoveryRequest(StrictModel):
    contractVersion: Literal[1]
    expectedRevision: Annotated[int, Field(ge=0, le=2**63 - 2)]
    sourceId: SafeName
    sourceToken: Annotated[str, StringConstraints(min_length=32, max_length=512)]
    criticalRuntimeSeconds: Annotated[int, Field(ge=60, le=3600)]
    restoreStableSeconds: Annotated[int, Field(ge=30, le=3600)]
    targets: list[PowerTarget] = Field(min_length=1, max_length=64)

    @field_validator("sourceToken")
    @classmethod
    def bounded_token(cls, value: str) -> str:
        try:
            if len(value.encode("utf-8")) > 512 or any(
                ord(char) < 32 or ord(char) == 127 for char in value
            ):
                raise ValueError("invalid_ups_token")
        except UnicodeError:
            raise ValueError("invalid_ups_token") from None
        return value

    @model_validator(mode="after")
    def coherent_targets(self):
        identities = [target.targetId for target in self.targets]
        orders = [target.shutdownOrder for target in self.targets]
        core_hosts = [target for target in self.targets if target.kind == "coreHost"]
        if (
            len(identities) != len(set(identities))
            or len(orders) != len(set(orders))
            or len(core_hosts) > 1
            or core_hosts and core_hosts[0].shutdownOrder != max(orders)
            or self.targets != sorted(self.targets, key=lambda item: item.shutdownOrder)
        ):
            raise ValueError("invalid_power_targets")
        return self


class PowerRecoveryPolicy(StrictModel):
    contractVersion: Literal[1]
    revision: Revision
    sourceId: SafeName
    criticalRuntimeSeconds: Annotated[int, Field(ge=60, le=3600)]
    restoreStableSeconds: Annotated[int, Field(ge=30, le=3600)]
    targets: list[PowerTarget] = Field(min_length=1, max_length=64)
    configuredAt: Timestamp


class PowerRecoveryPolicyResponse(StrictModel):
    policy: PowerRecoveryPolicy | None


class UpsPowerEvent(StrictModel):
    contractVersion: Literal[1]
    eventId: Identity
    sourceId: SafeName
    sourceRevision: Revision
    sequence: Revision
    state: Literal["online", "onBattery", "lowBattery"]
    chargePercent: Annotated[int, Field(ge=0, le=100)]
    runtimeSeconds: Annotated[int, Field(ge=0, le=86400)]
    observedAt: Timestamp

    @model_validator(mode="after")
    def coherent_state(self):
        if self.state == "online" and self.runtimeSeconds != 0:
            raise ValueError("online_runtime_must_be_zero")
        return self


class PowerStepReceipt(StrictModel):
    stepId: Identity
    sequence: Revision
    action: Literal[
        "holdNewWork",
        "drainActiveWork",
        "checkpointDatabase",
        "shutdownTarget",
        "startTarget",
        "releaseNewWork",
    ]
    targetId: Identity | None
    targetKind: Literal["service", "proxmoxGuest", "networkDevice", "coreHost"] | None
    state: Literal[
        "queued", "executing", "succeeded", "failed", "skipped", "uncertain"
    ]
    resultCode: Literal[
        "pending",
        "completed",
        "no_active_work",
        "active_work_timeout",
        "checkpoint_failed",
        "effect_failed",
        "restore_disabled",
        "reconciliation_required",
        "reconciled_current_state",
    ]
    createdAt: Timestamp
    updatedAt: Timestamp

    @model_validator(mode="after")
    def coherent_target(self):
        targeted = self.action in {"shutdownTarget", "startTarget"}
        if targeted != (self.targetId is not None and self.targetKind is not None):
            raise ValueError("invalid_power_step_target")
        return self


class PowerRecoveryRun(StrictModel):
    runId: Identity
    policyRevision: Revision
    triggerEventId: Identity
    state: Literal[
        "draining",
        "shuttingDown",
        "protected",
        "restoring",
        "completed",
        "failed",
    ]
    gateState: Literal["open", "held"]
    createdAt: Timestamp
    updatedAt: Timestamp
    restoreEligibleAt: Timestamp | None
    failureCode: Literal[
        "active_work_timeout", "checkpoint_failed", "effect_failed"
    ] | None
    steps: list[PowerStepReceipt] = Field(max_length=134)


class PowerRecoveryStatus(StrictModel):
    policy: PowerRecoveryPolicy | None
    sourceState: Literal["unconfigured", "online", "onBattery", "lowBattery"]
    gateState: Literal["open", "held"]
    lastSequence: Annotated[int, Field(ge=0, le=2**63 - 1)]
    lastObservedAt: Timestamp | None
    activeRun: PowerRecoveryRun | None
    recentRuns: list[PowerRecoveryRun] = Field(max_length=20)


class UpsEventReceipt(StrictModel):
    accepted: Literal[True]
    duplicate: bool
    status: PowerRecoveryStatus


class RetryPowerRecoveryRequest(StrictModel):
    contractVersion: Literal[1]
    expectedUpdatedAt: Timestamp


class ReconcilePowerRecoveryRequest(StrictModel):
    contractVersion: Literal[1]
    expectedUpdatedAt: Timestamp


class PowerEffectRequest(StrictModel):
    contractVersion: Literal[1]
    runId: Identity
    stepId: Identity
    action: Literal["shutdown", "start"]
    target: PowerTarget
    deadlineAt: Timestamp


class PowerEffectReceipt(StrictModel):
    contractVersion: Literal[1]
    runId: Identity
    stepId: Identity
    targetId: Identity
    action: Literal["shutdown", "start"]
    status: Literal["completed"]
    observedState: Literal["running", "stopped"]
    completedAt: Timestamp

    @model_validator(mode="after")
    def expected_state(self):
        expected = "stopped" if self.action == "shutdown" else "running"
        if self.observedState != expected:
            raise ValueError("power_effect_readback_mismatch")
        return self


class PowerEffectObservation(StrictModel):
    contractVersion: Literal[1]
    runId: Identity
    stepId: Identity
    targetId: Identity
    action: Literal["shutdown", "start"]
    observedState: Literal["running", "stopped"]
    observedAt: Timestamp
