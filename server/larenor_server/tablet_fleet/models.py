import math
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, HomeScope, Identity, Revision


ManagementMode = Literal["standard", "deviceOwner"]
CommandKind = Literal["syncProfile", "refreshDashboard", "restartClient", "lockKiosk"]
CommandResult = Literal["succeeded", "denied", "failed", "unsupported"]


def safe_text(value: str) -> str:
    if any(ord(char) < 32 or ord(char) == 127 or 0xD800 <= ord(char) <= 0xDFFF for char in value):
        raise ValueError("invalid_text")
    value = value.strip()
    if not value:
        raise ValueError("invalid_text")
    return value


class Versioned(FrozenModel):
    schemaVersion: Literal[1]

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class RegisterTablet(Versioned):
    registrationId: Identity
    name: str = Field(min_length=1, max_length=80)
    platform: Literal["android"]
    managementMode: ManagementMode
    clientVersion: str = Field(min_length=1, max_length=64, pattern=r"^[0-9A-Za-z.+_-]+$")
    appliedProfileRevision: Revision

    _name = field_validator("name")(safe_text)


class TabletHeartbeat(Versioned):
    expectedRevision: Revision
    clientVersion: str = Field(min_length=1, max_length=64, pattern=r"^[0-9A-Za-z.+_-]+$")
    appliedProfileRevision: Revision


class UpdateTabletProfile(Versioned):
    expectedRevision: Revision
    desiredProfileRevision: Revision


class TabletRef(HomeScope):
    kind: Literal["managed_tablet"]
    id: Identity


class TabletRecord(FrozenModel):
    schemaVersion: Literal[1]
    ref: TabletRef
    revision: Revision
    name: str
    platform: Literal["android"]
    managementMode: ManagementMode
    capabilities: list[str]
    clientVersion: str
    desiredProfileRevision: Revision
    appliedProfileRevision: Revision
    state: Literal["active", "revoked"]
    profileState: Literal["current", "updateRequired"]
    lastSeenAt: float


class StoredTablet(FrozenModel):
    name: str = Field(min_length=1, max_length=80)
    platform: Literal["android"]
    managementMode: ManagementMode
    clientVersion: str = Field(min_length=1, max_length=64, pattern=r"^[0-9A-Za-z.+_-]+$")
    desiredProfileRevision: Revision
    appliedProfileRevision: Revision

    _name = field_validator("name")(safe_text)


class TabletResponse(FrozenModel):
    tablet: TabletRecord


class TabletList(FrozenModel):
    schemaVersion: Literal[1]
    scope: HomeScope
    tablets: list[TabletRecord] = Field(max_length=256)


class IssueTabletCommand(Versioned):
    expectedDeviceRevision: Revision
    expectedPolicyRevision: Revision
    requestKey: str = Field(min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")
    command: CommandKind
    expiresAt: float

    @field_validator("expiresAt", mode="before")
    @classmethod
    def finite_expiry(cls, value):
        if type(value) is not float or not math.isfinite(value):
            raise ValueError("invalid_expiry")
        return value


class PollTabletCommands(Versioned):
    expectedDeviceRevision: Revision
    expectedPolicyRevision: Revision
    after: int = Field(default=0, ge=0, le=2**63 - 1)
    limit: int = Field(default=20, ge=1, le=50)


class CompleteTabletCommand(Versioned):
    expectedDeviceRevision: Revision
    expectedPolicyRevision: Revision
    sequence: int = Field(ge=1, le=2**63 - 1)
    result: CommandResult
    appliedProfileRevision: Revision


class TabletCommand(FrozenModel):
    schemaVersion: Literal[1]
    id: Identity
    sequence: int = Field(ge=1, le=2**63 - 1)
    command: CommandKind
    requiredMode: ManagementMode
    policyRevision: Revision
    expiresAt: float
    state: Literal["pending", "delivered", "completed", "expired"]
    result: CommandResult | Literal["expired"] | None
    createdAt: float
    completedAt: float | None


class TabletCommandResponse(FrozenModel):
    command: TabletCommand


class TabletCommandPage(FrozenModel):
    schemaVersion: Literal[1]
    tabletRevision: Revision
    commands: list[TabletCommand] = Field(max_length=50)
    nextAfter: int | None

    @model_validator(mode="after")
    def ordered(self):
        sequences = [item.sequence for item in self.commands]
        if sequences != sorted(set(sequences)):
            raise ValueError("invalid_command_order")
        return self
