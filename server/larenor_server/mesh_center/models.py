"""Closed contracts for Zigbee/Thread health and supported Zigbee OTA."""

from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision, Snapshot

TimestampMs = Annotated[int, Field(ge=0, le=2**63 - 1)]
Percent = Annotated[int, Field(ge=0, le=100)]
Version = Annotated[
    str,
    Field(
        min_length=5,
        max_length=32,
        pattern=r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$",
    ),
]
SafeText = Annotated[
    str,
    Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9][A-Za-z0-9 ._+:/-]*$"),
]
Signature = Annotated[
    str,
    Field(min_length=128, max_length=128, pattern=r"^[0-9a-f]{128}$"),
]


class MeshAuthority(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    accountId: Identity
    accountRevision: Revision
    memberRevision: Revision
    sessionFamilyId: Identity
    role: Literal["admin", "member"]
    active: bool
    canObserveMesh: bool
    canUpdateMesh: bool


class CoordinatorNode(FrozenModel):
    schemaVersion: Literal[1]
    nodeId: Identity
    revision: Revision
    providerRevision: Revision
    protocol: Literal["zigbee"]
    channel: int = Field(ge=11, le=26)
    firmwareVersion: Version
    online: bool


class BorderRouterNode(FrozenModel):
    schemaVersion: Literal[1]
    nodeId: Identity
    revision: Revision
    providerRevision: Revision
    routeRevision: Revision
    protocol: Literal["thread"]
    firmwareVersion: Version
    online: bool


class MeshDevice(FrozenModel):
    schemaVersion: Literal[1]
    deviceId: Identity
    revision: Revision
    providerRevision: Revision
    routeRevision: Revision
    protocol: Literal["zigbee", "thread"]
    manufacturer: SafeText
    model: SafeText
    hardwareRevision: SafeText
    firmwareVersion: Version
    powerSource: Literal["mains", "battery"]
    batteryPercent: Percent | None
    reachable: bool
    updating: bool
    parentId: Identity
    routeDepth: int = Field(ge=1, le=32)
    lastSeenAtMs: TimestampMs

    @model_validator(mode="after")
    def coherent_power(self):
        if (self.powerSource == "mains") != (self.batteryPercent is None):
            raise ValueError("invalid_power_state")
        if self.parentId == self.deviceId:
            raise ValueError("invalid_route")
        return self


class MeshTopology(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    revision: Revision
    providerRevision: Revision
    capturedAtMs: TimestampMs
    coordinator: CoordinatorNode
    borderRouters: list[BorderRouterNode] = Field(max_length=32)
    devices: list[MeshDevice] = Field(max_length=1_024)

    @model_validator(mode="after")
    def unique_nodes(self):
        ids = [self.coordinator.nodeId]
        ids.extend(node.nodeId for node in self.borderRouters)
        ids.extend(device.deviceId for device in self.devices)
        if len(ids) != len(set(ids)):
            raise ValueError("duplicate_mesh_node")
        return self


class ChannelObservation(FrozenModel):
    channel: int = Field(ge=11, le=26)
    utilizationPercent: Percent
    energyDbm: int = Field(ge=-120, le=0)


class InterferenceSnapshot(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    revision: Revision
    providerRevision: Revision
    capturedAtMs: TimestampMs
    channels: list[ChannelObservation] = Field(min_length=1, max_length=16)

    @field_validator("channels")
    @classmethod
    def unique_channels(cls, value):
        channels = [item.channel for item in value]
        if len(channels) != len(set(channels)):
            raise ValueError("duplicate_channel")
        return value


class ChannelAdvisory(FrozenModel):
    advisory: Literal[True]
    currentChannel: int = Field(ge=11, le=26)
    recommendedChannel: int = Field(ge=11, le=26)
    currentUtilizationPercent: Percent
    recommendedUtilizationPercent: Percent
    reason: Literal["lower_interference", "current_channel_best"]
    applied: Literal[False]


class MeshHealthReport(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    topologyRevision: Revision
    interferenceRevision: Revision
    readOnly: Literal[True]
    status: Literal["healthy", "degraded", "unavailable"]
    offlineDeviceIds: list[Identity]
    lowBatteryDeviceIds: list[Identity]
    threadBorderRouterCount: int = Field(ge=0, le=32)
    offlineBorderRouterIds: list[Identity]
    channelAdvisory: ChannelAdvisory


class FirmwareCatalogEntry(FrozenModel):
    schemaVersion: Literal[1]
    firmwareId: Identity
    protocol: Literal["zigbee", "thread"]
    manufacturer: SafeText
    model: SafeText
    compatibleHardwareRevisions: list[SafeText] = Field(min_length=1, max_length=32)
    sourceVersions: list[Version] = Field(min_length=1, max_length=64)
    version: Version
    sha256: Snapshot
    sizeBytes: int = Field(ge=1, le=256 * 1024 * 1024)
    minimumBatteryPercent: int = Field(ge=20, le=100)
    requiresMains: bool

    @model_validator(mode="after")
    def unique_compatibility(self):
        if len(self.compatibleHardwareRevisions) != len(
            set(self.compatibleHardwareRevisions)
        ) or len(self.sourceVersions) != len(set(self.sourceVersions)):
            raise ValueError("duplicate_compatibility")
        return self


class FirmwareCatalog(FrozenModel):
    schemaVersion: Literal[1]
    catalogId: Identity
    revision: Revision
    providerRevision: Revision
    generatedAtMs: TimestampMs
    expiresAtMs: TimestampMs
    signingKeyId: Identity
    entries: list[FirmwareCatalogEntry] = Field(min_length=1, max_length=2_048)
    signature: Signature

    @model_validator(mode="after")
    def coherent_catalog(self):
        if self.expiresAtMs <= self.generatedAtMs:
            raise ValueError("invalid_catalog_window")
        ids = [entry.firmwareId for entry in self.entries]
        if len(ids) != len(set(ids)):
            raise ValueError("duplicate_firmware")
        return self


class FirmwareUpdatePreview(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    accountId: Identity
    accountRevision: Revision
    memberRevision: Revision
    sessionFamilyId: Identity
    topologyRevision: Revision
    topologyProviderRevision: Revision
    coordinatorRevision: Revision
    deviceId: Identity
    expectedDeviceRevision: Revision
    expectedResultRevision: Revision
    expectedProviderRevision: Revision
    expectedRouteRevision: Revision
    catalogId: Identity
    catalogRevision: Revision
    catalogProviderRevision: Revision
    firmwareId: Identity
    firmwareSha256: Snapshot
    targetVersion: Version
    expiresAtMs: TimestampMs
    confirmationToken: Snapshot


class FirmwareUpdateCommand(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    accountId: Identity
    accountRevision: Revision
    memberRevision: Revision
    sessionFamilyId: Identity
    topologyRevision: Revision
    topologyProviderRevision: Revision
    coordinatorRevision: Revision
    deviceId: Identity
    expectedDeviceRevision: Revision
    expectedResultRevision: Revision
    expectedProviderRevision: Revision
    expectedRouteRevision: Revision
    catalogRevision: Revision
    catalogProviderRevision: Revision
    firmwareId: Identity
    firmwareSha256: Snapshot
    firmwareSizeBytes: int = Field(ge=1, le=256 * 1024 * 1024)
    targetVersion: Version


class FirmwareUpdateReadback(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    coreId: Identity
    homeId: Identity
    deviceId: Identity
    previousDeviceRevision: Revision
    deviceRevision: Revision
    providerRevision: Revision
    routeRevision: Revision
    installedVersion: Version
    installedSha256: Snapshot
    status: Literal["installed"]


class FirmwareUpdateResult(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    status: Literal["confirmed", "uncertain"]
    reason: Literal["lost_ack", "readback_mismatch"] | None
    readbackVerified: bool
    readback: FirmwareUpdateReadback | None

    @model_validator(mode="after")
    def coherent_result(self):
        if self.status == "confirmed":
            if (
                not self.readbackVerified
                or self.readback is None
                or self.reason is not None
            ):
                raise ValueError("invalid_result")
        elif self.readbackVerified or self.readback is not None or self.reason is None:
            raise ValueError("invalid_result")
        return self


class MeshCenterSnapshot(FrozenModel):
    """Exact provider material returned to one authenticated Client route."""

    schemaVersion: Literal[1]
    authority: MeshAuthority
    topology: MeshTopology
    interference: InterferenceSnapshot
    catalog: FirmwareCatalog
    health: MeshHealthReport

    @model_validator(mode="after")
    def coherent_scope(self):
        if (
            (
                self.authority.coreId,
                self.authority.homeId,
                self.authority.homeRevision,
            )
            != (
                self.topology.coreId,
                self.topology.homeId,
                self.topology.homeRevision,
            )
            or (self.interference.coreId, self.interference.homeId)
            != (
                self.authority.coreId,
                self.authority.homeId,
            )
            or (self.health.coreId, self.health.homeId)
            != (
                self.authority.coreId,
                self.authority.homeId,
            )
        ):
            raise ValueError("mesh_scope_mismatch")
        return self


class MeshPreviewRequest(FrozenModel):
    schemaVersion: Literal[1]
    authority: MeshAuthority
    topology: MeshTopology
    catalog: FirmwareCatalog
    deviceId: Identity
    firmwareId: Identity
    requestId: Identity


class MeshConfirmRequest(FrozenModel):
    schemaVersion: Literal[1]
    authority: MeshAuthority
    preview: FirmwareUpdatePreview
    confirmationToken: Snapshot
