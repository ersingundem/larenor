from datetime import datetime, timezone
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision, ResourceRef


class PreviewRequest(FrozenModel):
    serviceId: Identity
    expectedServiceRevision: Revision
    expectedRevision: Revision
    expectedAclRevision: Revision
    expectedBindingId: Identity | None


class ConfirmRequest(FrozenModel):
    previewId: Identity


class Binding(FrozenModel):
    schemaVersion: Literal[1] = 1
    id: Identity
    revision: Revision
    ref: ResourceRef
    serviceId: Identity
    serviceRevision: Revision


class NodeSummary(FrozenModel):
    node: str = Field(min_length=1, max_length=64, pattern=r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
    status: Literal['online', 'offline']
    cpuRatio: float = Field(ge=0, le=1)
    memoryUsedBytes: int = Field(ge=0, le=2**63 - 1)
    memoryTotalBytes: int = Field(ge=1, le=2**63 - 1)
    uptimeSeconds: int = Field(ge=0, le=2**63 - 1)

    @model_validator(mode='after')
    def used_within_total(self):
        if self.memoryUsedBytes > self.memoryTotalBytes:
            raise ValueError('invalid_summary')
        return self


class GuestSummary(FrozenModel):
    vmId: int = Field(ge=1, le=999999999)
    node: str = Field(min_length=1, max_length=64, pattern=r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
    kind: Literal['qemu', 'lxc']
    name: str = Field(min_length=1, max_length=128)
    status: Literal['running', 'stopped']
    cpuRatio: float = Field(ge=0, le=1)
    memoryUsedBytes: int = Field(ge=0, le=2**63 - 1)
    memoryTotalBytes: int = Field(ge=1, le=2**63 - 1)

    @field_validator('name')
    @classmethod
    def safe_name(cls, value):
        if any(ord(c) < 32 or ord(c) == 127 or 0xD800 <= ord(c) <= 0xDFFF for c in value):
            raise ValueError('invalid_summary')
        return value

    @model_validator(mode='after')
    def used_within_total(self):
        if self.memoryUsedBytes > self.memoryTotalBytes:
            raise ValueError('invalid_summary')
        return self


class StorageSummary(FrozenModel):
    storage: str = Field(min_length=1, max_length=64, pattern=r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
    node: str = Field(min_length=1, max_length=64, pattern=r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
    kind: str = Field(min_length=1, max_length=64, pattern=r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
    active: bool
    usedBytes: int = Field(ge=0, le=2**63 - 1)
    totalBytes: int = Field(ge=1, le=2**63 - 1)
    availableBytes: int = Field(ge=0, le=2**63 - 1)

    @model_validator(mode='after')
    def valid_capacity(self):
        if self.usedBytes > self.totalBytes or self.availableBytes > self.totalBytes:
            raise ValueError('invalid_summary')
        return self


class RecentTaskSummary(FrozenModel):
    taskId: str = Field(min_length=64, max_length=64, pattern=r'^[0-9a-f]{64}$')
    node: str = Field(min_length=1, max_length=64, pattern=r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
    kind: str = Field(min_length=1, max_length=64, pattern=r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
    status: Literal['running', 'succeeded', 'failed']
    startedAt: str = Field(min_length=20, max_length=40,
                           pattern=r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)$')
    finishedAt: str | None = Field(min_length=20, max_length=40,
                                   pattern=r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)$')

    @field_validator('startedAt', 'finishedAt')
    @classmethod
    def utc_timestamp(cls, value):
        if value is None:
            return value
        try:
            parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        except (TypeError, ValueError):
            raise ValueError('invalid_summary') from None
        if parsed.tzinfo is None or parsed.utcoffset() != timezone.utc.utcoffset(parsed):
            raise ValueError('invalid_summary')
        return value

    @model_validator(mode='after')
    def valid_lifecycle(self):
        if (self.status == 'running') != (self.finishedAt is None):
            raise ValueError('invalid_summary')
        if self.finishedAt is not None:
            started = datetime.fromisoformat(self.startedAt.replace('Z', '+00:00'))
            finished = datetime.fromisoformat(self.finishedAt.replace('Z', '+00:00'))
            if finished < started:
                raise ValueError('invalid_summary')
        return self


class Summary(FrozenModel):
    nodes: list[NodeSummary] = Field(max_length=32)
    guests: list[GuestSummary] = Field(max_length=256)
    storages: list[StorageSummary] = Field(max_length=64)
    recentTasks: list[RecentTaskSummary] = Field(max_length=20)

    @model_validator(mode='after')
    def unique_keys(self):
        keys = ([n.node for n in self.nodes],
                [(g.kind, g.vmId) for g in self.guests],
                [(s.node, s.storage) for s in self.storages],
                [t.taskId for t in self.recentTasks])
        if any(len(values) != len(set(values)) for values in keys):
            raise ValueError('invalid_summary')
        return self


class Preview(FrozenModel):
    id: Identity
    expiresInMs: int = Field(ge=1, le=60000)
    binding: Binding
    summary: Summary


class PreviewResponse(FrozenModel):
    preview: Preview


class BindingResponse(FrozenModel):
    binding: Binding


class Snapshot(FrozenModel):
    schemaVersion: Literal[1] = 1
    ref: ResourceRef
    bindingId: Identity
    bindingRevision: Revision
    resourceRevision: Revision
    aclRevision: Revision
    serviceId: Identity
    serviceRevision: Revision
    observedAt: str = Field(max_length=40)
    remainingTtlMs: int = Field(ge=0, le=5000)
    summary: Summary


class SnapshotResponse(FrozenModel):
    snapshot: Snapshot
