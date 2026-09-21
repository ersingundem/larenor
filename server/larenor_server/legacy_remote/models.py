"""Closed public contracts for opaque legacy remote command bindings."""

from typing import Annotated, Literal

from pydantic import Field, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision, Snapshot


TimestampMs = Annotated[int, Field(ge=0, le=2**63 - 1)]
RemoteProtocol = Literal["ir", "rf"]
RemoteProvider = Literal["home_assistant", "isolated_bridge"]
RemoteCommandKey = Literal[
    "power_toggle",
    "power_on",
    "power_off",
    "volume_up",
    "volume_down",
    "mute",
    "channel_up",
    "channel_down",
    "input_next",
    "menu",
    "back",
    "up",
    "down",
    "left",
    "right",
    "select",
    "play",
    "pause",
    "stop",
]


class RemoteAuthority(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    accountId: Identity
    accountRevision: Revision
    memberRevision: Revision
    sessionFamilyId: Identity
    active: bool
    canControlLegacyRemote: bool


class RemoteDevice(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    deviceId: Identity
    revision: Revision
    providerType: RemoteProvider
    providerId: Identity
    providerRevision: Revision
    bridgeId: Identity
    bridgeRevision: Revision
    protocol: RemoteProtocol
    stored: bool
    reachable: bool
    providerVerified: bool


class RemoteCommandDefinition(FrozenModel):
    schemaVersion: Literal[1]
    bindingId: Identity
    key: RemoteCommandKey
    maxRepeats: int = Field(ge=1, le=3)
    maxHoldMs: int = Field(ge=0, le=2_000)


class RemoteCommandProfile(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    profileId: Identity
    revision: Revision
    deviceId: Identity
    expectedDeviceRevision: Revision
    providerId: Identity
    expectedProviderRevision: Revision
    codeSetId: Identity
    codeSetRevision: Revision
    protocol: RemoteProtocol
    commands: list[RemoteCommandDefinition] = Field(min_length=1, max_length=64)

    @model_validator(mode="after")
    def unique_commands(self):
        keys = [command.key for command in self.commands]
        bindings = [command.bindingId for command in self.commands]
        if len(keys) != len(set(keys)) or len(bindings) != len(set(bindings)):
            raise ValueError("duplicate_remote_command")
        return self


class RemoteCodeBinding(FrozenModel):
    """An opaque code-set lookup. Signal bytes stay inside the provider worker."""

    schemaVersion: Literal[1]
    bindingId: Identity
    key: RemoteCommandKey
    codeSetId: Identity
    codeSetRevision: Revision


class RemoteCommandPreview(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    accountId: Identity
    accountRevision: Revision
    memberRevision: Revision
    sessionFamilyId: Identity
    deviceId: Identity
    deviceRevision: Revision
    providerType: RemoteProvider
    providerId: Identity
    providerRevision: Revision
    bridgeId: Identity
    bridgeRevision: Revision
    profileId: Identity
    profileRevision: Revision
    codeSetId: Identity
    codeSetRevision: Revision
    bindingId: Identity
    key: RemoteCommandKey
    repeats: int = Field(ge=1, le=3)
    holdMs: int = Field(ge=0, le=2_000)
    expiresAtMs: TimestampMs
    confirmationToken: Snapshot


class RemoteWorkerCommand(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    accountId: Identity
    accountRevision: Revision
    memberRevision: Revision
    sessionFamilyId: Identity
    deviceId: Identity
    deviceRevision: Revision
    providerType: RemoteProvider
    providerId: Identity
    providerRevision: Revision
    bridgeId: Identity
    bridgeRevision: Revision
    profileId: Identity
    profileRevision: Revision
    codeSetId: Identity
    codeSetRevision: Revision
    bindingId: Identity
    key: RemoteCommandKey
    repeats: int = Field(ge=1, le=3)
    holdMs: int = Field(ge=0, le=2_000)


class RemoteDeliveryReceipt(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    coreId: Identity
    homeId: Identity
    providerId: Identity
    providerRevision: Revision
    bridgeId: Identity
    bridgeRevision: Revision
    deviceId: Identity
    deviceRevision: Revision
    profileId: Identity
    profileRevision: Revision
    codeSetId: Identity
    codeSetRevision: Revision
    bindingId: Identity
    key: RemoteCommandKey
    repeats: int = Field(ge=1, le=3)
    holdMs: int = Field(ge=0, le=2_000)
    status: Literal["emitted"]


class RemoteCommandResult(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    status: Literal["dispatched", "uncertain"]
    reason: Literal["lost_ack", "readback_mismatch"] | None
    deliveryVerified: bool
    deviceStateVerified: Literal[False]
    receipt: RemoteDeliveryReceipt | None

    @model_validator(mode="after")
    def coherent_result(self):
        if self.status == "dispatched":
            if not self.deliveryVerified or self.receipt is None or self.reason is not None:
                raise ValueError("invalid_result")
        elif self.deliveryVerified or self.receipt is not None or self.reason is None:
            raise ValueError("invalid_result")
        return self


class RemoteCatalogItem(FrozenModel):
    """Secret-free projection needed by the Android control surface."""

    schemaVersion: Literal[1]
    name: str = Field(min_length=1, max_length=128, pattern=r"^[^\x00-\x1f\x7f]+$")
    device: RemoteDevice
    profile: RemoteCommandProfile

    @model_validator(mode="after")
    def coherent_item(self):
        if (
            self.device.coreId,
            self.device.homeId,
            self.device.deviceId,
            self.device.revision,
            self.device.providerId,
            self.device.providerRevision,
            self.device.protocol,
        ) != (
            self.profile.coreId,
            self.profile.homeId,
            self.profile.deviceId,
            self.profile.expectedDeviceRevision,
            self.profile.providerId,
            self.profile.expectedProviderRevision,
            self.profile.protocol,
        ):
            raise ValueError("invalid_remote_catalog_item")
        return self


class RemoteCatalog(FrozenModel):
    schemaVersion: Literal[1]
    authority: RemoteAuthority
    items: list[RemoteCatalogItem] = Field(max_length=100)

    @model_validator(mode="after")
    def coherent_catalog(self):
        identities = [item.device.deviceId for item in self.items]
        profiles = [item.profile.profileId for item in self.items]
        if len(identities) != len(set(identities)) or len(profiles) != len(set(profiles)):
            raise ValueError("duplicate_remote_catalog_item")
        if any(
            (item.device.coreId, item.device.homeId)
            != (self.authority.coreId, self.authority.homeId)
            for item in self.items
        ):
            raise ValueError("invalid_remote_catalog_scope")
        return self


class RemotePreviewRequest(FrozenModel):
    schemaVersion: Literal[1]
    authority: RemoteAuthority
    requestId: Identity
    deviceId: Identity
    expectedDeviceRevision: Revision
    providerId: Identity
    expectedProviderRevision: Revision
    bridgeId: Identity
    expectedBridgeRevision: Revision
    profileId: Identity
    expectedProfileRevision: Revision
    codeSetId: Identity
    expectedCodeSetRevision: Revision
    bindingId: Identity
    commandKey: RemoteCommandKey
    repeats: int = Field(ge=1, le=3)
    holdMs: int = Field(ge=0, le=2_000)


class RemoteConfirmRequest(FrozenModel):
    schemaVersion: Literal[1]
    authority: RemoteAuthority
    preview: RemoteCommandPreview
    confirmationToken: Snapshot
