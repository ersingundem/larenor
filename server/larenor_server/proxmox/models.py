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


class LatestBackupSummary(RecentTaskSummary):
    kind: Literal['vzdump']


class GuestSnapshotSummary(FrozenModel):
    node: str = Field(min_length=1, max_length=64,
                      pattern=r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
    kind: Literal['qemu', 'lxc']
    vmId: int = Field(ge=1, le=999999999)
    snapshotCount: int = Field(ge=0, le=256)
    latestAt: str | None = Field(min_length=20, max_length=40,
                                 pattern=r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)$')

    @field_validator('latestAt')
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
    def count_matches_timestamp(self):
        if (self.snapshotCount == 0) != (self.latestAt is None):
            raise ValueError('invalid_summary')
        return self


class ProtectionSummary(FrozenModel):
    state: Literal['available', 'empty', 'partial']
    guestCount: int = Field(ge=0, le=256)
    scannedGuestCount: int = Field(ge=0, le=8)
    truncated: bool
    latestBackup: LatestBackupSummary | None
    snapshots: list[GuestSnapshotSummary] = Field(max_length=8)

    @model_validator(mode='after')
    def valid_rollup(self):
        if (len(self.snapshots) != self.scannedGuestCount or
                self.guestCount < self.scannedGuestCount or
                self.truncated != (self.guestCount > self.scannedGuestCount)):
            raise ValueError('invalid_summary')
        identities = [(item.node, item.kind, item.vmId) for item in self.snapshots]
        if len(identities) != len(set(identities)):
            raise ValueError('invalid_summary')
        has_data = (self.latestBackup is not None or
                    any(item.snapshotCount for item in self.snapshots))
        expected = 'partial' if self.truncated else 'available' if has_data else 'empty'
        if self.state != expected:
            raise ValueError('invalid_summary')
        return self


class RetentionWarning(FrozenModel):
    kind: Literal['backup_missing', 'backup_stale', 'backup_failed',
                  'restore_point_missing', 'coverage_partial', 'storage_pressure']
    severity: Literal['attention', 'critical']
    affectedCount: int = Field(ge=1, le=256)
    observedPercent: int | None = Field(ge=0, le=100)
    ageSeconds: int | None = Field(ge=0, le=2**63 - 1)

    @model_validator(mode='after')
    def valid_shape(self):
        if ((self.kind == 'storage_pressure') != (self.observedPercent is not None) or
                (self.kind == 'backup_stale') != (self.ageSeconds is not None)):
            raise ValueError('invalid_summary')
        return self


class RetentionSummary(FrozenModel):
    state: Literal['healthy', 'attention', 'critical']
    latestSuccessfulBackupAt: str | None = Field(min_length=20, max_length=40,
                                                  pattern=r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)$')
    latestSuccessfulBackupAgeSeconds: int | None = Field(ge=0, le=2**63 - 1)
    evaluatedGuestCount: int = Field(ge=0, le=8)
    protectedGuestCount: int = Field(ge=0, le=8)
    coverageTruncated: bool
    highestStorageUsedPercent: int | None = Field(ge=0, le=100)
    warnings: list[RetentionWarning] = Field(max_length=6)

    @field_validator('latestSuccessfulBackupAt')
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
    def valid_rollup(self):
        if ((self.latestSuccessfulBackupAt is None) !=
                (self.latestSuccessfulBackupAgeSeconds is None) or
                self.protectedGuestCount > self.evaluatedGuestCount):
            raise ValueError('invalid_summary')
        if len({warning.kind for warning in self.warnings}) != len(self.warnings):
            raise ValueError('invalid_summary')
        expected = ('healthy' if not self.warnings else
                    'critical' if any(warning.severity == 'critical'
                                      for warning in self.warnings) else 'attention')
        if self.state != expected:
            raise ValueError('invalid_summary')
        return self


class MaintenanceWarning(FrozenModel):
    warningId: str = Field(min_length=64, max_length=64, pattern=r'^[0-9a-f]{64}$')
    kind: Literal['node_offline', 'storage_offline', 'node_cpu_pressure',
                  'node_memory_pressure', 'storage_pressure', 'recent_task_failed']
    severity: Literal['warning', 'critical']
    node: str = Field(min_length=1, max_length=64, pattern=r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
    storage: str | None = Field(min_length=1, max_length=64,
                                pattern=r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
    observedPercent: int | None = Field(ge=0, le=100)
    thresholdPercent: int | None = Field(ge=0, le=100)
    relatedTaskId: str | None = Field(min_length=64, max_length=64,
                                      pattern=r'^[0-9a-f]{64}$')

    @model_validator(mode='after')
    def valid_shape(self):
        values = (self.observedPercent, self.thresholdPercent)
        if self.kind in ('node_offline', 'storage_offline'):
            if self.severity != 'critical' or any(value is not None for value in values):
                raise ValueError('invalid_summary')
        elif self.kind == 'recent_task_failed':
            if self.severity != 'warning' or any(value is not None for value in values):
                raise ValueError('invalid_summary')
        else:
            low = 75 if self.kind == 'node_cpu_pressure' else 80
            expected = 90 if self.severity == 'critical' else low
            if (self.observedPercent is None or self.thresholdPercent != expected or
                    self.observedPercent < expected or
                    self.severity == 'warning' and self.observedPercent >= 90):
                raise ValueError('invalid_summary')
        if ((self.kind in ('storage_offline', 'storage_pressure')) !=
                (self.storage is not None)):
            raise ValueError('invalid_summary')
        if ((self.kind == 'recent_task_failed') != (self.relatedTaskId is not None)):
            raise ValueError('invalid_summary')
        return self


class MaintenanceSummary(FrozenModel):
    state: Literal['healthy', 'attention', 'critical']
    warningCount: int = Field(ge=0, le=148)
    truncated: bool
    warnings: list[MaintenanceWarning] = Field(max_length=32)

    @model_validator(mode='after')
    def valid_rollup(self):
        if len({warning.warningId for warning in self.warnings}) != len(self.warnings):
            raise ValueError('invalid_summary')
        if self.truncated != (self.warningCount > len(self.warnings)):
            raise ValueError('invalid_summary')
        if not self.truncated and self.warningCount != len(self.warnings):
            raise ValueError('invalid_summary')
        has_critical = any(warning.severity == 'critical' for warning in self.warnings)
        expected = ('healthy' if self.warningCount == 0 else
                    'critical' if has_critical else 'attention')
        if self.state != expected:
            raise ValueError('invalid_summary')
        return self


class Summary(FrozenModel):
    nodes: list[NodeSummary] = Field(max_length=32)
    guests: list[GuestSummary] = Field(max_length=256)
    storages: list[StorageSummary] = Field(max_length=64)
    recentTasks: list[RecentTaskSummary] = Field(max_length=20)
    maintenance: MaintenanceSummary
    protection: ProtectionSummary
    retention: RetentionSummary

    @model_validator(mode='after')
    def unique_keys(self):
        keys = ([n.node for n in self.nodes],
                [(g.kind, g.vmId) for g in self.guests],
                [(s.node, s.storage) for s in self.storages],
                [t.taskId for t in self.recentTasks])
        if any(len(values) != len(set(values)) for values in keys):
            raise ValueError('invalid_summary')
        nodes = {node.node for node in self.nodes}
        storages = {(storage.node, storage.storage) for storage in self.storages}
        failed = {task.taskId: task.node for task in self.recentTasks
                  if task.status == 'failed'}
        semantic = set()
        for warning in self.maintenance.warnings:
            if warning.node not in nodes:
                raise ValueError('invalid_summary')
            if warning.storage is not None and (warning.node, warning.storage) not in storages:
                raise ValueError('invalid_summary')
            if warning.relatedTaskId is not None and failed.get(warning.relatedTaskId) != warning.node:
                raise ValueError('invalid_summary')
            key = (warning.kind, warning.node, warning.storage, warning.relatedTaskId)
            if key in semantic:
                raise ValueError('invalid_summary')
            semantic.add(key)
        guest_keys = {(guest.node, guest.kind, guest.vmId) for guest in self.guests}
        if any((item.node, item.kind, item.vmId) not in guest_keys
               for item in self.protection.snapshots):
            raise ValueError('invalid_summary')
        if self.protection.latestBackup is not None:
            backup = self.protection.latestBackup.model_dump()
            if not any(task.model_dump() == backup for task in self.recentTasks):
                raise ValueError('invalid_summary')
        retention = self.retention
        active_ratios = [(storage.usedBytes * 100 + storage.totalBytes // 2) //
                         storage.totalBytes
                         for storage in self.storages if storage.active]
        highest = max(active_ratios) if active_ratios else None
        successful = [task for task in self.recentTasks
                      if task.kind == 'vzdump' and task.status == 'succeeded']
        latest_success = (max(successful, key=lambda task: task.finishedAt)
                          if successful else None)
        if (retention.evaluatedGuestCount != self.protection.scannedGuestCount or
                retention.protectedGuestCount != sum(
                    item.snapshotCount > 0 for item in self.protection.snapshots) or
                retention.coverageTruncated != self.protection.truncated or
                retention.highestStorageUsedPercent != highest or
                (latest_success.finishedAt if latest_success else None) !=
                retention.latestSuccessfulBackupAt):
            raise ValueError('invalid_summary')
        failed = sum(task.kind == 'vzdump' and task.status == 'failed'
                     for task in self.recentTasks)
        missing = retention.evaluatedGuestCount - retention.protectedGuestCount
        unseen = self.protection.guestCount - retention.evaluatedGuestCount
        expected = []
        if latest_success is None:
            expected.append(('backup_missing', 'critical', 1, None, None))
        elif retention.latestSuccessfulBackupAgeSeconds >= 86400:
            age = retention.latestSuccessfulBackupAgeSeconds
            expected.append(('backup_stale', 'critical' if age >= 259200 else 'attention',
                             1, None, age))
        if failed:
            expected.append(('backup_failed', 'critical', failed, None, None))
        if missing:
            expected.append(('restore_point_missing', 'attention', missing, None, None))
        if unseen:
            expected.append(('coverage_partial', 'attention', unseen, None, None))
        pressured = [ratio for ratio in active_ratios if ratio >= 80]
        if pressured:
            observed = max(pressured)
            expected.append(('storage_pressure', 'critical' if observed >= 90 else 'attention',
                             len(pressured), observed, None))
        actual = [(warning.kind, warning.severity, warning.affectedCount,
                   warning.observedPercent, warning.ageSeconds)
                  for warning in retention.warnings]
        if actual != expected:
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
