from typing import Annotated, Literal

from pydantic import Field, IPvAnyAddress, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, ResourceRef, Revision

SafeName = Annotated[str, Field(min_length=1, max_length=128)]
Counter = Annotated[int, Field(ge=0, le=2**63 - 1)]
WifiBand = Literal["2.4", "5", "6"]
SignalDbm = Annotated[int, Field(ge=-127, le=0)]


def _safe(value):
    if value is None:
        return value
    if any(
        ord(c) < 32
        or 127 <= ord(c) <= 159
        or 0xD800 <= ord(c) <= 0xDFFF
        or 0x202A <= ord(c) <= 0x202E
        or 0x2066 <= ord(c) <= 0x2069
        or ord(c) == 0xFEFF
        for c in value
    ):
        raise ValueError("unsafe_text")
    return value


class BindingPreviewRequest(FrozenModel):
    serviceId: Identity
    expectedServiceRevision: Revision
    expectedResourceRevision: Revision
    expectedAclRevision: Revision
    expectedBindingId: Identity | None


class ConfirmRequest(FrozenModel):
    previewId: Identity


class KeeneticBinding(FrozenModel):
    id: Identity
    revision: Revision
    ref: ResourceRef
    serviceId: Identity
    serviceRevision: Revision


class RouterStatus(FrozenModel):
    online: bool
    publicIp: IPvAnyAddress | None
    uptimeSeconds: Counter
    firmware: str | None = Field(default=None, max_length=80)
    firmwareRevision: Revision | None = Field(
        default=None, exclude_if=lambda value: value is None
    )
    statusRevision: Revision | None = Field(
        default=None, exclude_if=lambda value: value is None
    )
    cpuPercent: Annotated[float, Field(ge=0, le=100)] | None
    memoryPercent: Annotated[float, Field(ge=0, le=100)] | None

    _firmware = field_validator("firmware")(_safe)


class InterfaceTelemetry(FrozenModel):
    id: SafeName
    name: SafeName
    kind: Literal["wan", "lan", "wifi", "vpn", "other"]
    online: bool
    address: str | None = Field(default=None, max_length=64)
    rxBytes: Counter
    txBytes: Counter
    guest: bool | None = Field(default=None, exclude_if=lambda value: value is None)
    ssid: str | None = Field(default=None, max_length=64, exclude_if=lambda value: value is None)
    band: WifiBand | None = Field(default=None, exclude_if=lambda value: value is None)
    channel: Annotated[int, Field(ge=1, le=233)] | None = Field(
        default=None, exclude_if=lambda value: value is None
    )
    signalDbm: SignalDbm | None = Field(default=None, exclude_if=lambda value: value is None)

    _id = field_validator("id", "name", "address", "ssid")(_safe)

    @model_validator(mode="after")
    def wifi_metadata_only(self):
        if self.kind != "wifi" and any(
            value is not None for value in (self.ssid, self.band, self.channel, self.signalDbm)
        ):
            raise ValueError("unexpected_wifi_metadata")
        return self


class TrafficTelemetry(FrozenModel):
    rxBytes: Counter
    txBytes: Counter
    downloadBps: Counter | None
    uploadBps: Counter | None


class HostTelemetry(FrozenModel):
    id: SafeName
    name: SafeName
    ipAddress: str = Field(min_length=2, max_length=64)
    macAddress: str = Field(min_length=17, max_length=17,
                            pattern=r"^[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}$")
    interfaceId: SafeName
    online: bool
    registered: bool
    internetAccess: Literal["allowed", "paused"] | None = Field(
        default=None, exclude_if=lambda value: value is None
    )
    band: WifiBand | None = Field(default=None, exclude_if=lambda value: value is None)
    signalDbm: SignalDbm | None = Field(default=None, exclude_if=lambda value: value is None)

    _text = field_validator("id", "name", "ipAddress", "interfaceId")(_safe)


class Telemetry(FrozenModel):
    status: RouterStatus
    interfaces: list[InterfaceTelemetry] = Field(min_length=1, max_length=64)
    traffic: TrafficTelemetry
    hosts: list[HostTelemetry] = Field(max_length=512)

    @model_validator(mode="after")
    def exact_references(self):
        ids = [item.id for item in self.interfaces]
        if len(set(ids)) != len(ids) or len({item.id for item in self.hosts}) != len(self.hosts):
            raise ValueError("duplicate_identity")
        if any(host.interfaceId not in ids for host in self.hosts):
            raise ValueError("unknown_interface")
        return self


class Preview(FrozenModel):
    id: Identity
    expiresInMs: Annotated[int, Field(ge=1, le=60000)]
    binding: KeeneticBinding
    snapshot: Telemetry


class PreviewResponse(FrozenModel):
    preview: Preview


class BindingResponse(FrozenModel):
    binding: KeeneticBinding


class ResourceSnapshot(FrozenModel):
    ref: ResourceRef
    bindingId: Identity
    bindingRevision: Revision
    serviceId: Identity
    serviceRevision: Revision
    resourceRevision: Revision
    aclRevision: Revision
    observedAt: str
    remainingTtlMs: Annotated[int, Field(ge=0, le=5000)]
    telemetry: Telemetry


class SnapshotResponse(FrozenModel):
    snapshot: ResourceSnapshot


class InterfaceDetail(FrozenModel):
    kind: Literal["interface"] = "interface"
    id: SafeName
    name: SafeName
    interfaceKind: Literal["wan", "lan", "wifi", "vpn", "other"]
    online: bool
    address: str | None = Field(default=None, max_length=64)
    rxBytes: Counter
    txBytes: Counter
    guest: bool | None = None
    ssid: str | None = Field(default=None, max_length=64)
    band: WifiBand | None = None
    channel: Annotated[int, Field(ge=1, le=233)] | None = None
    signalDbm: SignalDbm | None = None

    _safe_text = field_validator("id", "name", "address", "ssid")(_safe)

    @model_validator(mode="after")
    def wifi_metadata_only(self):
        if self.interfaceKind != "wifi" and any(
            value is not None for value in (self.ssid, self.band, self.channel, self.signalDbm)
        ):
            raise ValueError("unexpected_wifi_metadata")
        return self


class ClientDetail(FrozenModel):
    kind: Literal["client"] = "client"
    id: str = Field(min_length=16, max_length=16, pattern=r"^[0-9a-f]{16}$")
    name: SafeName
    ipAddress: str = Field(min_length=2, max_length=64)
    macHash: str = Field(min_length=16, max_length=16, pattern=r"^[0-9a-f]{16}$")
    interfaceId: SafeName
    online: bool
    registered: bool
    internetAccess: Literal["allowed", "paused"] | None = None
    band: WifiBand | None = None
    signalDbm: SignalDbm | None = None

    _safe_text = field_validator("name", "ipAddress", "interfaceId")(_safe)

    @model_validator(mode="after")
    def stable_private_identity(self):
        if self.id != self.macHash:
            raise ValueError("identity_mismatch")
        return self


class DetailsPage(FrozenModel):
    entries: list[InterfaceDetail | ClientDetail] = Field(max_length=100)
    snapshot: str = Field(min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$")
    nextAfter: str | None = Field(
        default=None, min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$"
    )
