from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, ResourceRef, Revision


SafeTarget = Annotated[str, Field(min_length=1, max_length=128)]
Action = Literal[
    "guest_wifi_enable",
    "guest_wifi_disable",
    "client_internet_pause",
    "client_internet_resume",
    "wan_reconnect",
]
Status = Literal[
    "accepted", "executing", "succeeded", "failed", "cancelled", "unknown"
]
Risk = Literal["low", "medium", "high"]


def _safe(value: str) -> str:
    if any(
        ord(char) < 32
        or 127 <= ord(char) <= 159
        or 0xD800 <= ord(char) <= 0xDFFF
        or 0x202A <= ord(char) <= 0x202E
        or 0x2066 <= ord(char) <= 0x2069
        or ord(char) == 0xFEFF
        for char in value
    ):
        raise ValueError("unsafe_text")
    return value


class TargetState(FrozenModel):
    """Exact read-side state required before one command can be previewed."""

    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    resourceId: Identity
    resourceRevision: Revision
    aclRevision: Revision
    bindingId: Identity
    bindingRevision: Revision
    serviceId: Identity
    serviceRevision: Revision
    firmwareVersion: str = Field(min_length=3, max_length=80)
    firmwareRevision: Revision
    stateRevision: Revision
    targetKind: Literal["guest_wifi", "client", "wan"]
    targetId: SafeTarget
    value: Literal["enabled", "disabled", "allowed", "paused", "online", "offline"]

    _target = field_validator("targetId")(_safe)

    @field_validator("firmwareVersion")
    @classmethod
    def supported_firmware(cls, value):
        _safe(value)
        if len(value) < 2 or value[0] not in "2345" or value[1] != ".":
            raise ValueError("unsupported_firmware")
        return value


class CommandRequest(FrozenModel):
    schemaVersion: Literal[1]
    action: Action
    target: TargetState
    expectedUserRevision: Revision
    requestId: Identity
    idempotencyKey: str = Field(min_length=43, max_length=43, pattern=r"^[A-Za-z0-9_-]{43}$")
    reason: str = Field(min_length=1, max_length=160)

    _reason = field_validator("reason")(_safe)

    @model_validator(mode="after")
    def action_matches_target(self):
        expected = {
            "guest_wifi_enable": ("guest_wifi", "disabled"),
            "guest_wifi_disable": ("guest_wifi", "enabled"),
            "client_internet_pause": ("client", "allowed"),
            "client_internet_resume": ("client", "paused"),
            "wan_reconnect": ("wan", "online"),
        }[self.action]
        if (self.target.targetKind, self.target.value) != expected:
            raise ValueError("action_state_mismatch")
        return self


class CommandPreview(FrozenModel):
    id: Identity
    confirmToken: str = Field(min_length=43, max_length=43, pattern=r"^[A-Za-z0-9_-]{43}$")
    requestId: Identity
    action: Action
    risk: Risk
    status: Literal["accepted"]
    target: TargetState
    expiresInMs: Annotated[int, Field(ge=1, le=60000)]


class SecondConfirmation(FrozenModel):
    token: str = Field(min_length=43, max_length=43, pattern=r"^[A-Za-z0-9_-]{43}$")
    risk: Literal["high"]
    expiresInMs: Annotated[int, Field(ge=1, le=30000)]


class CommandReceipt(FrozenModel):
    requestId: Identity
    action: Action
    target: TargetState
    status: Literal["succeeded", "failed", "cancelled", "unknown"]
    code: str = Field(min_length=1, max_length=80)
    transitions: list[Status] = Field(min_length=2, max_length=3)

    _code = field_validator("code")(_safe)


class CommandAttribution(FrozenModel):
    schemaVersion: Literal[1]
    correlationId: Identity
    actorId: Identity
    source: Literal["core_api", "core_recovery", "unknown"]
    reason: Literal[
        "explicit_admin_request", "interrupted_after_restart", "unknown"
    ]
    serviceId: Identity
    serviceRevision: Revision

    @model_validator(mode="after")
    def source_matches_reason(self):
        expected = {
            "core_api": "explicit_admin_request",
            "core_recovery": "interrupted_after_restart",
            "unknown": "unknown",
        }[self.source]
        if self.reason != expected:
            raise ValueError("attribution_mismatch")
        return self


class AttributedCommandEvent(FrozenModel):
    schemaVersion: Literal[1]
    sequence: Annotated[int, Field(ge=1, le=3072)]
    attribution: CommandAttribution
    requestId: Identity
    action: Action
    status: Status
    target: TargetState
    code: str = Field(min_length=1, max_length=80)

    _event_code = field_validator("code")(_safe)

    @model_validator(mode="after")
    def trace_matches_target(self):
        if (
            self.attribution.correlationId != self.requestId
            or self.attribution.serviceId != self.target.serviceId
            or self.attribution.serviceRevision != self.target.serviceRevision
        ):
            raise ValueError("attribution_mismatch")
        return self


class AttributedCommandHistory(FrozenModel):
    schemaVersion: Literal[1]
    ref: ResourceRef
    events: list[AttributedCommandEvent] = Field(max_length=50)
    verified: Literal[True]


class CommandTargetDescriptor(FrozenModel):
    target: TargetState
    actions: list[Action] = Field(min_length=1, max_length=1)
    expectedUserRevision: Revision


class CommandTargetResponse(FrozenModel):
    descriptors: list[CommandTargetDescriptor] = Field(min_length=1, max_length=128)
