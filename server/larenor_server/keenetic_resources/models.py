from typing import Annotated, Literal

from pydantic import Field, IPvAnyAddress, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, ResourceRef, Revision

SafeName = Annotated[str, Field(min_length=1, max_length=128)]
Counter = Annotated[int, Field(ge=0, le=2**63 - 1)]


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

    _id = field_validator("id", "name", "address")(_safe)


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
