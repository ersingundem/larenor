"""Strict read-only planning for authenticated component restore payloads.

This module selects no paths and performs no host or Engine writes.  It binds
an already authenticated backup capture to an exact, current installation
authority snapshot so a later restore stage cannot choose a different target.
"""

from dataclasses import dataclass, field, fields
import hashlib
import math
import re
import secrets
import time

from .models import MAX_COMPONENT_BYTES, MAX_COMPONENT_VOLUME_BYTES, BackupManifest
from .service import (
    BackupCapture,
    _is_authenticated_backup_capture,
    _validate_payload_contract,
)


_COMPONENT_ID = re.compile(r"[a-z][a-z0-9_]{0,31}\Z")
_INSTALLATION_ID = re.compile(r"[0-9a-f]{32}\Z")
_BINDING_ID = re.compile(r"[0-9a-f]{64}\Z")
_VOLUME_ID = re.compile(r"[a-z][a-z0-9-]{0,127}\Z")
_RESOURCE_ID = re.compile(r"[a-z][a-z0-9-]{0,39}\Z")
_VERSION = re.compile(r"[A-Za-z0-9_.+-]{1,64}\Z")
_SNAPSHOT_ID = re.compile(r"[0-9a-f]{32}\Z")
_DIGEST = re.compile(r"[0-9a-f]{64}\Z")


class ComponentRestorePlanError(RuntimeError):
    """Static planning failure; capture bytes and target details stay private."""

    def __init__(self):
        super().__init__("component_restore_unavailable")

    def __repr__(self):
        return "ComponentRestorePlanError()"


def _exact(value, kind):
    return type(value) is kind and set(vars(value)) == {
        item.name for item in fields(kind)
    }


def _identity(value, expression):
    return type(value) is str and expression.fullmatch(value) is not None


def _revision(value):
    return type(value) is int and 1 <= value <= 2**63 - 1


@dataclass(frozen=True, repr=False)
class ComponentRestoreAuthorityVolume:
    """Opaque current volume binding supplied by a read-only authority."""

    volume_id: str
    binding_id: str = field(repr=False)
    binding_revision: int

    def __post_init__(self):
        if (
            not _identity(self.volume_id, _VOLUME_ID)
            or not _identity(self.binding_id, _BINDING_ID)
            or not _revision(self.binding_revision)
        ):
            raise ComponentRestorePlanError()

    def __repr__(self):
        return "ComponentRestoreAuthorityVolume(<private>)"


@dataclass(frozen=True, repr=False)
class ComponentRestoreAuthorityTarget:
    """One exact installed service view with no host path or credential."""

    service_id: str
    installation_id: str = field(repr=False)
    service_version: str
    config_schema_version: int
    data_schema_version: str
    installation_revision: int
    volumes: tuple[ComponentRestoreAuthorityVolume, ...] = field(repr=False)

    def __post_init__(self):
        try:
            volume_ids = [item.volume_id for item in self.volumes]
            binding_ids = [item.binding_id for item in self.volumes]
            if (
                not _identity(self.service_id, _COMPONENT_ID)
                or not _identity(self.installation_id, _INSTALLATION_ID)
                or not _identity(self.service_version, _VERSION)
                or not _revision(self.config_schema_version)
                or not _identity(self.data_schema_version, _VERSION)
                or not _revision(self.installation_revision)
                or type(self.volumes) is not tuple
                or not 1 <= len(self.volumes) <= 3
                or any(
                    not _exact(item, ComponentRestoreAuthorityVolume)
                    for item in self.volumes
                )
                or volume_ids != sorted(volume_ids)
                or len(set(volume_ids)) != len(volume_ids)
                or len(set(binding_ids)) != len(binding_ids)
                or any(
                    not item.startswith(f"{self.service_id.replace('_', '-')}-")
                    for item in volume_ids
                )
            ):
                raise ValueError()
        except (AttributeError, TypeError, ValueError):
            raise ComponentRestorePlanError() from None

    def __repr__(self):
        return "ComponentRestoreAuthorityTarget(<private>)"


@dataclass(frozen=True, repr=False)
class ComponentRestoreVolumeTarget:
    resource_id: str
    volume_id: str
    binding_id: str = field(repr=False)
    binding_revision: int
    byte_length: int
    sha256: str

    def __post_init__(self):
        if (
            not _identity(self.resource_id, _RESOURCE_ID)
            or not _identity(self.volume_id, _VOLUME_ID)
            or self.resource_id != f"component-{self.volume_id}"
            or not _identity(self.binding_id, _BINDING_ID)
            or not _revision(self.binding_revision)
            or type(self.byte_length) is not int
            or not 1 <= self.byte_length <= MAX_COMPONENT_VOLUME_BYTES
            or not _identity(self.sha256, _DIGEST)
        ):
            raise ComponentRestorePlanError()

    def __repr__(self):
        return "ComponentRestoreVolumeTarget(<private>)"


@dataclass(frozen=True, repr=False)
class ComponentRestoreTarget:
    service_id: str
    installation_id: str = field(repr=False)
    service_version: str
    config_schema_version: int
    data_schema_version: str
    installation_revision: int
    volumes: tuple[ComponentRestoreVolumeTarget, ...] = field(repr=False)

    def __post_init__(self):
        try:
            resource_ids = [item.resource_id for item in self.volumes]
            binding_ids = [item.binding_id for item in self.volumes]
            if (
                not _identity(self.service_id, _COMPONENT_ID)
                or not _identity(self.installation_id, _INSTALLATION_ID)
                or not _identity(self.service_version, _VERSION)
                or not _revision(self.config_schema_version)
                or not _identity(self.data_schema_version, _VERSION)
                or not _revision(self.installation_revision)
                or type(self.volumes) is not tuple
                or not 1 <= len(self.volumes) <= 3
                or any(
                    not _exact(item, ComponentRestoreVolumeTarget)
                    for item in self.volumes
                )
                or resource_ids != sorted(resource_ids)
                or len(set(resource_ids)) != len(resource_ids)
                or len(set(binding_ids)) != len(binding_ids)
                or any(
                    not item.startswith(
                        f"component-{self.service_id.replace('_', '-')}-"
                    )
                    for item in resource_ids
                )
            ):
                raise ValueError()
        except (AttributeError, TypeError, ValueError):
            raise ComponentRestorePlanError() from None

    def __repr__(self):
        return "ComponentRestoreTarget(<private>)"


@dataclass(frozen=True, repr=False)
class ComponentRestorePlan:
    snapshot_id: str
    targets: tuple[ComponentRestoreTarget, ...] = field(repr=False)
    total_byte_length: int

    def __post_init__(self):
        try:
            service_ids = [item.service_id for item in self.targets]
            installation_ids = [item.installation_id for item in self.targets]
            binding_ids = [
                volume.binding_id
                for item in self.targets
                for volume in item.volumes
            ]
            computed = sum(
                volume.byte_length
                for item in self.targets
                for volume in item.volumes
            )
            if (
                not _identity(self.snapshot_id, _SNAPSHOT_ID)
                or type(self.targets) is not tuple
                or not 1 <= len(self.targets) <= 128
                or any(
                    not _exact(item, ComponentRestoreTarget)
                    for item in self.targets
                )
                or service_ids != sorted(service_ids)
                or len(set(service_ids)) != len(service_ids)
                or len(set(installation_ids)) != len(installation_ids)
                or len(set(binding_ids)) != len(binding_ids)
                or type(self.total_byte_length) is not int
                or self.total_byte_length != computed
                or not 1 <= self.total_byte_length <= MAX_COMPONENT_BYTES
            ):
                raise ValueError()
        except (AttributeError, TypeError, ValueError):
            raise ComponentRestorePlanError() from None

    def __repr__(self):
        return "ComponentRestorePlan(<private>)"


@dataclass(frozen=True, repr=False)
class ComponentRestoreRollbackReceipt:
    """Opaque snapshot proving that one exact target can be rolled back."""

    resource_id: str
    binding_id: str = field(repr=False)
    binding_revision: int
    receipt_id: str = field(repr=False)
    byte_length: int
    sha256: str

    def __post_init__(self):
        if (
            not _identity(self.resource_id, _RESOURCE_ID)
            or not self.resource_id.startswith("component-")
            or not _identity(self.binding_id, _BINDING_ID)
            or not _revision(self.binding_revision)
            or not _identity(self.receipt_id, _DIGEST)
            or type(self.byte_length) is not int
            or not 0 <= self.byte_length <= MAX_COMPONENT_VOLUME_BYTES
            or not _identity(self.sha256, _DIGEST)
        ):
            raise ComponentRestorePlanError()

    def __repr__(self):
        return "ComponentRestoreRollbackReceipt(<private>)"


@dataclass(frozen=True, repr=False)
class ComponentRestoreStageReceipt:
    """Opaque off-target stage bound to its rollback snapshot and payload."""

    resource_id: str
    binding_id: str = field(repr=False)
    binding_revision: int
    rollback_receipt_id: str = field(repr=False)
    stage_id: str = field(repr=False)
    byte_length: int
    sha256: str

    def __post_init__(self):
        if (
            not _identity(self.resource_id, _RESOURCE_ID)
            or not self.resource_id.startswith("component-")
            or not _identity(self.binding_id, _BINDING_ID)
            or not _revision(self.binding_revision)
            or not _identity(self.rollback_receipt_id, _DIGEST)
            or not _identity(self.stage_id, _DIGEST)
            or type(self.byte_length) is not int
            or not 1 <= self.byte_length <= MAX_COMPONENT_VOLUME_BYTES
            or not _identity(self.sha256, _DIGEST)
        ):
            raise ComponentRestorePlanError()

    def __repr__(self):
        return "ComponentRestoreStageReceipt(<private>)"


@dataclass(frozen=True, repr=False)
class ComponentRestoreBatchReceipt:
    snapshot_id: str
    rollbacks: tuple[ComponentRestoreRollbackReceipt, ...] = field(repr=False)
    stages: tuple[ComponentRestoreStageReceipt, ...] = field(repr=False)

    def __post_init__(self):
        try:
            rollback_resources = [item.resource_id for item in self.rollbacks]
            stage_resources = [item.resource_id for item in self.stages]
            if (
                not _identity(self.snapshot_id, _SNAPSHOT_ID)
                or type(self.rollbacks) is not tuple
                or type(self.stages) is not tuple
                or not self.rollbacks
                or len(self.rollbacks) != len(self.stages)
                or any(
                    not _exact(item, ComponentRestoreRollbackReceipt)
                    for item in self.rollbacks
                )
                or any(
                    not _exact(item, ComponentRestoreStageReceipt)
                    for item in self.stages
                )
                or rollback_resources != sorted(rollback_resources)
                or rollback_resources != stage_resources
                or len(set(rollback_resources)) != len(rollback_resources)
                or len({item.receipt_id for item in self.rollbacks})
                != len(self.rollbacks)
                or len({item.stage_id for item in self.stages}) != len(self.stages)
            ):
                raise ValueError()
        except (AttributeError, TypeError, ValueError):
            raise ComponentRestorePlanError() from None

    def __repr__(self):
        return "ComponentRestoreBatchReceipt(<private>)"


class ComponentRestoreBoundary:
    """Disabled production boundary; a reviewed host adapter must be injected."""

    def acquire(self, _plan, _deadline):
        raise ComponentRestorePlanError()


def _authority_snapshot(authority):
    values = authority.snapshot()
    if (
        type(values) is not tuple
        or not 1 <= len(values) <= 128
        or any(not _exact(item, ComponentRestoreAuthorityTarget) for item in values)
    ):
        raise ComponentRestorePlanError()
    service_ids = []
    installation_ids = []
    binding_ids = []
    for item in values:
        # Re-run all invariants because frozen dataclasses can still arrive
        # from deserializers or test doubles that bypassed __post_init__.
        item.__post_init__()
        service_ids.append(item.service_id)
        installation_ids.append(item.installation_id)
        binding_ids.extend(volume.binding_id for volume in item.volumes)
    if (
        service_ids != sorted(service_ids)
        or len(set(service_ids)) != len(service_ids)
        or len(set(installation_ids)) != len(installation_ids)
        or len(set(binding_ids)) != len(binding_ids)
    ):
        raise ComponentRestorePlanError()
    return values


def _capture_resources(capture):
    if (
        not _exact(capture, BackupCapture)
        or not _is_authenticated_backup_capture(capture)
        or type(capture.manifest) is not BackupManifest
        or type(capture.payloads) is not dict
    ):
        raise ComponentRestorePlanError()
    _validate_payload_contract(capture)
    manifest = capture.manifest
    if (
        manifest.contractVersion != 2
        or manifest.consistencyBoundary is None
        or manifest.consistencyBoundary.mode
        != "core_write_lock_and_component_quiescence"
        or manifest.consistencyBoundary.maxDurationSeconds != 5
        or not manifest.components
    ):
        raise ComponentRestorePlanError()
    resources = {item.id: item for item in manifest.resources}
    if (
        len(resources) != len(manifest.resources)
        or set(capture.payloads) != set(resources)
        or any(type(value) is not bytes for value in capture.payloads.values())
    ):
        raise ComponentRestorePlanError()
    total = 0
    for component in manifest.components:
        for resource_id in component.volumeResourceIds:
            resource = resources.get(resource_id)
            payload = capture.payloads.get(resource_id)
            if (
                resource is None
                or resource.kind != "componentData"
                or resource.version != "component-v1"
                or type(resource.byteLength) is not int
                or not 1 <= resource.byteLength <= MAX_COMPONENT_VOLUME_BYTES
                or type(payload) is not bytes
                or len(payload) != resource.byteLength
                or not secrets.compare_digest(
                    hashlib.sha256(payload).hexdigest(), resource.sha256
                )
            ):
                raise ComponentRestorePlanError()
            total += resource.byteLength
            if total > MAX_COMPONENT_BYTES:
                raise ComponentRestorePlanError()
    return resources, total


def plan_component_restore(capture, authority):
    """Bind authenticated component bytes to a stable read-only target view."""

    try:
        resources, total = _capture_resources(capture)
        initial = _authority_snapshot(authority)
        components = {item.serviceId: item for item in capture.manifest.components}
        by_service = {item.service_id: item for item in initial}
        if (
            len(components) != len(capture.manifest.components)
            or set(components) != set(by_service)
        ):
            raise ComponentRestorePlanError()
        targets = []
        for service_id in sorted(components):
            component = components[service_id]
            current = by_service[service_id]
            expected_volume_ids = tuple(
                item.removeprefix("component-")
                for item in component.volumeResourceIds
            )
            if (
                current.service_version != component.serviceVersion
                or current.config_schema_version
                != component.configSchemaVersion
                or current.data_schema_version != component.dataSchemaVersion
                or tuple(item.volume_id for item in current.volumes)
                != expected_volume_ids
            ):
                raise ComponentRestorePlanError()
            volumes = []
            for authority_volume, resource_id in zip(
                current.volumes, component.volumeResourceIds, strict=True
            ):
                resource = resources[resource_id]
                volumes.append(
                    ComponentRestoreVolumeTarget(
                        resource_id=resource_id,
                        volume_id=authority_volume.volume_id,
                        binding_id=authority_volume.binding_id,
                        binding_revision=authority_volume.binding_revision,
                        byte_length=resource.byteLength,
                        sha256=resource.sha256,
                    )
                )
            targets.append(
                ComponentRestoreTarget(
                    service_id=service_id,
                    installation_id=current.installation_id,
                    service_version=current.service_version,
                    config_schema_version=current.config_schema_version,
                    data_schema_version=current.data_schema_version,
                    installation_revision=current.installation_revision,
                    volumes=tuple(volumes),
                )
            )
        if _authority_snapshot(authority) != initial:
            raise ComponentRestorePlanError()
        return ComponentRestorePlan(
            snapshot_id=capture.manifest.snapshotId,
            targets=tuple(targets),
            total_byte_length=total,
        )
    except ComponentRestorePlanError:
        raise
    except Exception:
        raise ComponentRestorePlanError() from None


def _plan_matches_capture(capture, plan):
    resources, total = _capture_resources(capture)
    if not _exact(plan, ComponentRestorePlan):
        raise ComponentRestorePlanError()
    plan.__post_init__()
    components = {item.serviceId: item for item in capture.manifest.components}
    targets = {item.service_id: item for item in plan.targets}
    if (
        plan.snapshot_id != capture.manifest.snapshotId
        or plan.total_byte_length != total
        or set(components) != set(targets)
    ):
        raise ComponentRestorePlanError()
    ordered = []
    for service_id in sorted(components):
        component = components[service_id]
        target = targets[service_id]
        if (
            target.service_version != component.serviceVersion
            or target.config_schema_version != component.configSchemaVersion
            or target.data_schema_version != component.dataSchemaVersion
            or tuple(item.resource_id for item in target.volumes)
            != tuple(component.volumeResourceIds)
        ):
            raise ComponentRestorePlanError()
        for volume in target.volumes:
            resource = resources[volume.resource_id]
            if (
                volume.byte_length != resource.byteLength
                or not secrets.compare_digest(volume.sha256, resource.sha256)
            ):
                raise ComponentRestorePlanError()
            ordered.append(volume)
    return tuple(ordered)


class ComponentRestoreCoordinator:
    """Stage a complete component batch before one authority-owned commit."""

    def __init__(self, boundary=None, *, monotonic=time.monotonic):
        if boundary is None:
            boundary = ComponentRestoreBoundary()
        if not callable(monotonic) or not callable(getattr(boundary, "acquire", None)):
            raise ComponentRestorePlanError()
        self._boundary = boundary
        self._monotonic = monotonic

    def _active(self, deadline):
        if (
            type(deadline) not in (int, float)
            or type(deadline) is bool
            or not math.isfinite(deadline)
            or self._monotonic() >= deadline
        ):
            raise ComponentRestorePlanError()

    @staticmethod
    def _rollback_matches(receipt, volume):
        return (
            _exact(receipt, ComponentRestoreRollbackReceipt)
            and receipt.resource_id == volume.resource_id
            and receipt.binding_id == volume.binding_id
            and receipt.binding_revision == volume.binding_revision
        )

    @staticmethod
    def _stage_matches(receipt, volume, rollback, payload):
        return (
            _exact(receipt, ComponentRestoreStageReceipt)
            and receipt.resource_id == volume.resource_id
            and receipt.binding_id == volume.binding_id
            and receipt.binding_revision == volume.binding_revision
            and receipt.rollback_receipt_id == rollback.receipt_id
            and receipt.byte_length == len(payload)
            and secrets.compare_digest(
                receipt.sha256, hashlib.sha256(payload).hexdigest()
            )
        )

    @staticmethod
    def _failure_cleanup(session, rollbacks, stages):
        try:
            session.rollback(tuple(rollbacks), tuple(stages))
        except Exception:
            pass
        finally:
            try:
                session.release()
            except Exception:
                pass

    @staticmethod
    def _failure_rollback(session, rollbacks, stages):
        try:
            session.rollback(tuple(rollbacks), tuple(stages))
        except Exception:
            pass

    def restore(self, capture, plan, *, deadline):
        """Return receipts only after an exact all-stage/revalidate/commit cut."""

        session = None
        rollbacks = []
        stages = []
        release_attempted = False
        try:
            volumes = _plan_matches_capture(capture, plan)
            self._active(deadline)
            session = self._boundary.acquire(plan, deadline)
            self._active(deadline)
            required = {
                "quiesce",
                "capture_rollback",
                "stage",
                "revalidate",
                "commit",
                "rollback",
                "release",
            }
            if any(not callable(getattr(session, name, None)) for name in required):
                raise ComponentRestorePlanError()
            if session.quiesce(plan.targets, deadline) is not True:
                raise ComponentRestorePlanError()
            self._active(deadline)

            # Capture the complete rollback set before staging the first new
            # byte. This also fixes the deterministic resource order.
            for volume in volumes:
                receipt = session.capture_rollback(volume, deadline)
                if not self._rollback_matches(receipt, volume):
                    raise ComponentRestorePlanError()
                rollbacks.append(receipt)
                self._active(deadline)
            if len({item.receipt_id for item in rollbacks}) != len(rollbacks):
                raise ComponentRestorePlanError()

            for volume, rollback in zip(volumes, rollbacks, strict=True):
                payload = capture.payloads[volume.resource_id]
                receipt = session.stage(volume, payload, rollback, deadline)
                if not self._stage_matches(receipt, volume, rollback, payload):
                    raise ComponentRestorePlanError()
                stages.append(receipt)
                self._active(deadline)
            if len({item.stage_id for item in stages}) != len(stages):
                raise ComponentRestorePlanError()

            if session.revalidate(plan, deadline) is not True:
                raise ComponentRestorePlanError()
            self._active(deadline)
            if session.commit(tuple(stages), tuple(rollbacks), deadline) is not True:
                raise ComponentRestorePlanError()
            self._active(deadline)
            if session.revalidate(plan, deadline) is not True:
                raise ComponentRestorePlanError()
            self._active(deadline)
            release_attempted = True
            if session.release() is not True:
                raise ComponentRestorePlanError()
        except Exception:
            if session is not None:
                if release_attempted:
                    self._failure_rollback(session, rollbacks, stages)
                else:
                    self._failure_cleanup(session, rollbacks, stages)
            raise ComponentRestorePlanError() from None
        return ComponentRestoreBatchReceipt(
            snapshot_id=plan.snapshot_id,
            rollbacks=tuple(rollbacks),
            stages=tuple(stages),
        )
