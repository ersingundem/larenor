import math
from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, HomeScope, Identity, Revision


ManagementMode = Literal["standard", "deviceOwner"]
CommandKind = Literal["syncProfile", "refreshDashboard", "restartClient", "lockKiosk"]
CommandResult = Literal["succeeded", "denied", "failed", "unsupported"]
ProfileRevision = Annotated[int, Field(ge=0, le=2**63 - 1)]


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


class TabletProfileDocument(Versioned):
    fullscreen: bool
    idleTimeoutSeconds: int = Field(ge=30, le=86_400)


class PublishTabletProfile(Versioned):
    expectedDeviceRevision: Revision
    expectedProfileRevision: ProfileRevision
    documentDigest: str = Field(pattern=r"^[0-9a-f]{64}$")
    document: TabletProfileDocument


class TabletProfilePublication(Versioned):
    deviceId: Identity
    deviceRevision: Revision
    revision: Revision
    digest: str = Field(pattern=r"^[0-9a-f]{64}$")
    document: TabletProfileDocument
    updatedAt: float

    @field_validator("updatedAt", mode="before")
    @classmethod
    def finite_update(cls, value):
        if type(value) is not float or not math.isfinite(value):
            raise ValueError("invalid_update")
        return value


class TabletProfilePublicationResponse(FrozenModel):
    publication: TabletProfilePublication


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


class KioskProfileSettings(FrozenModel):
    fullscreen: bool
    idleTimeoutSeconds: int = Field(ge=30, le=86_400)


class KioskProfileTarget(FrozenModel):
    deviceId: Identity
    expectedDeviceRevision: Revision


class PreviewKioskProfileRollout(Versioned):
    requestDigest: str = Field(pattern=r"^[0-9a-f]{64}$")
    channel: Literal["stable", "beta"]
    profileRevision: Revision
    rolloutPercent: int = Field(ge=1, le=100)
    settings: KioskProfileSettings
    targets: list[KioskProfileTarget] = Field(min_length=1, max_length=256)

    @model_validator(mode="after")
    def unique_targets(self):
        ids = [target.deviceId for target in self.targets]
        if ids != sorted(set(ids)):
            raise ValueError("invalid_target_order")
        return self


class KioskReleaseIdentity(FrozenModel):
    applicationId: Literal["com.ersingundem.larenor"]
    certificateSha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    versionCode: int = Field(ge=1, le=2_147_483_647)
    versionName: str = Field(min_length=1, max_length=80)
    apkSha256: str = Field(pattern=r"^[0-9a-f]{64}$")


class KioskRolloutDevice(FrozenModel):
    deviceId: Identity
    deviceRevision: Revision
    appliedProfileRevision: Revision
    desiredProfileRevision: Revision
    state: Literal[
        "current", "ready", "deferred", "appUpdateRequired", "revoked"
    ]
    differences: list[Literal["applicationVersion", "profileRevision"]] = Field(
        max_length=2
    )


class KioskProfileRolloutPreview(FrozenModel):
    schemaVersion: Literal[1]
    scope: HomeScope
    requestDigest: str = Field(pattern=r"^[0-9a-f]{64}$")
    profileRevision: Revision
    rolloutPercent: int = Field(ge=1, le=100)
    profileSeal: str = Field(pattern=r"^[0-9a-f]{64}$")
    release: KioskReleaseIdentity
    devices: list[KioskRolloutDevice] = Field(min_length=1, max_length=256)
