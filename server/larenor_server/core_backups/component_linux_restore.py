"""Linux component restore boundaries bound to durable installation receipts."""

import ctypes
import hashlib
import io
import json
import math
import os
import stat
import sys
import time
import zipfile

from .component_docker_adapter import UnixDockerComponentSnapshotAdapter
from .component_installation_authority import (
    DurableComponentInstallationAuthority,
)
from .component_restore import (
    ComponentRestoreAuthorityTarget,
    ComponentRestoreAuthorityVolume,
    ComponentRestorePlan,
    ComponentRestorePlanError,
    ComponentRestoreRollbackReceipt,
    ComponentRestoreStageReceipt,
    ComponentRestoreVolumeTarget,
)
from .component_snapshot_provider import (
    ComponentVolumeSource,
    archive_component_directory,
)
from .models import MAX_COMPONENT_VOLUME_BYTES


def _canonical(value):
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
    ).encode("ascii")


def _digest(value):
    return hashlib.sha256(_canonical(value)).hexdigest()


def _volume_identity(receipt):
    intent = receipt.intent
    binding = intent.binding
    resource = binding.resource
    return {
        "volumeId": receipt.volume_id,
        "target": receipt.target,
        "journalId": binding.journal_id,
        "ownershipNonce": binding.ownership_nonce,
        "resourceId": resource.resourceId,
        "operationId": resource.operationId,
        "name": resource.name,
        "revision": intent.receipt.revision,
    }


def _installation_identity(receipt):
    installed = receipt.installed
    binding = installed.binding
    return {
        "serviceId": receipt.service_id,
        "installationId": receipt.installation_id,
        "containerId": receipt.container_id,
        "serviceVersion": receipt.service_version,
        "configSchemaVersion": receipt.config_schema_version,
        "dataSchemaVersion": receipt.data_schema_version,
        "journalId": installed.journal_id,
        "jobId": installed.job_id,
        "createDispatchId": installed.create_dispatch_id,
        "startDispatchId": installed.start_dispatch_id,
        "platform": binding.platform,
        "imageId": binding.image_id,
        "networkId": binding.network_id,
        "mounts": [
            {
                "name": item.name,
                "target": item.target,
                "readOnly": item.read_only,
            }
            for item in binding.mounts
        ],
        "specificationSha256": hashlib.sha256(binding.specification).hexdigest(),
        "imageConfigurationSha256": hashlib.sha256(
            binding.image_configuration
        ).hexdigest(),
        "volumes": [_volume_identity(item) for item in receipt.volumes],
    }


def _revision(receipt):
    value = int(_digest(_installation_identity(receipt))[:16], 16)
    return max(1, value & (2**63 - 1))


class DurableComponentRestoreAuthority:
    """Expose exact restore targets without paths, payloads or credentials."""

    def __init__(self, authority):
        if type(authority) is not DurableComponentInstallationAuthority:
            raise ComponentRestorePlanError()
        self._authority = authority

    @staticmethod
    def _target(receipt):
        return ComponentRestoreAuthorityTarget(
            service_id=receipt.service_id,
            installation_id=receipt.installation_id,
            service_version=receipt.service_version,
            config_schema_version=receipt.config_schema_version,
            data_schema_version=receipt.data_schema_version,
            installation_revision=_revision(receipt),
            volumes=tuple(
                ComponentRestoreAuthorityVolume(
                    volume_id=volume.volume_id,
                    binding_id=_digest(_volume_identity(volume)),
                    binding_revision=volume.intent.receipt.revision,
                )
                for volume in receipt.volumes
            ),
        )

    def snapshot(self):
        try:
            receipts = self._authority.snapshot()
            return tuple(self._target(item) for item in receipts)
        except ComponentRestorePlanError:
            raise
        except Exception:
            raise ComponentRestorePlanError() from None


def _active(deadline):
    if (
        type(deadline) not in (int, float)
        or type(deadline) is bool
        or not math.isfinite(deadline)
        or time.monotonic() >= deadline
    ):
        raise ComponentRestorePlanError()


def _close(descriptor):
    try:
        os.close(descriptor)
    except OSError:
        pass


def _directory_digest(descriptor, deadline):
    payload = archive_component_directory(descriptor, deadline)
    return len(payload), hashlib.sha256(payload).hexdigest()


def _remove_tree(parent, name, deadline):
    _active(deadline)
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=parent,
    )
    try:
        names = os.listdir(descriptor)
        if len(names) > 4096:
            raise ComponentRestorePlanError()
        for child in names:
            _active(deadline)
            info = os.stat(child, dir_fd=descriptor, follow_symlinks=False)
            if stat.S_ISDIR(info.st_mode):
                _remove_tree(descriptor, child, deadline)
            elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
                os.unlink(child, dir_fd=descriptor)
            else:
                raise ComponentRestorePlanError()
        os.fsync(descriptor)
    finally:
        _close(descriptor)
    os.rmdir(name, dir_fd=parent)
    os.fsync(parent)


def _mkdir_path(root, parts, mode):
    descriptor = os.dup(root)
    try:
        for index, part in enumerate(parts):
            try:
                os.mkdir(
                    part, mode if index == len(parts) - 1 else 0o700, dir_fd=descriptor
                )
            except FileExistsError:
                pass
            following = os.open(
                part,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=descriptor,
            )
            if index == len(parts) - 1:
                os.fchmod(following, mode)
            os.fsync(descriptor)
            _close(descriptor)
            descriptor = following
        result = descriptor
        descriptor = -1
        return result
    finally:
        if descriptor >= 0:
            _close(descriptor)


def _extract_archive(payload, descriptor, deadline):
    try:
        with zipfile.ZipFile(io.BytesIO(payload), mode="r") as archive:
            entries = archive.infolist()
            if not 1 <= len(entries) <= 4096:
                raise ValueError()
            seen = set()
            total = 0
            for entry in entries:
                _active(deadline)
                raw = entry.filename
                directory = raw.endswith("/")
                name = raw[:-1] if directory else raw
                parts = tuple(name.split("/"))
                mode = (entry.external_attr >> 16) & 0xFFFF
                kind = stat.S_IFMT(mode)
                permissions = stat.S_IMODE(mode)
                if (
                    entry.create_system != 3
                    or entry.flag_bits & 1
                    or entry.compress_type != zipfile.ZIP_DEFLATED
                    or not parts
                    or len(parts) > 32
                    or any(
                        not part
                        or part in {".", ".."}
                        or "\\" in part
                        or len(part.encode("utf-8", "strict")) > 255
                        for part in parts
                    )
                    or name in seen
                    or permissions & 0o7000
                    or directory
                    and kind != stat.S_IFDIR
                    or not directory
                    and kind != stat.S_IFREG
                    or directory
                    and entry.file_size != 0
                ):
                    raise ValueError()
                seen.add(name)
                total += entry.file_size
                if total > MAX_COMPONENT_VOLUME_BYTES:
                    raise ValueError()
                if directory:
                    child = _mkdir_path(descriptor, parts, permissions)
                    os.fsync(child)
                    _close(child)
                    continue
                parent = _mkdir_path(descriptor, parts[:-1], 0o700)
                try:
                    child = os.open(
                        parts[-1],
                        os.O_WRONLY
                        | os.O_CREAT
                        | os.O_EXCL
                        | os.O_NOFOLLOW
                        | os.O_CLOEXEC,
                        permissions,
                        dir_fd=parent,
                    )
                    try:
                        with archive.open(entry, mode="r") as source:
                            remaining = entry.file_size
                            while remaining:
                                _active(deadline)
                                chunk = source.read(min(64 * 1024, remaining))
                                if not chunk:
                                    raise ValueError()
                                os.write(child, chunk)
                                remaining -= len(chunk)
                            if source.read(1):
                                raise ValueError()
                        os.fchmod(child, permissions)
                        os.fsync(child)
                    finally:
                        _close(child)
                    os.fsync(parent)
                finally:
                    _close(parent)
            os.fsync(descriptor)
    except ComponentRestorePlanError:
        raise
    except Exception:
        raise ComponentRestorePlanError() from None


class LinuxRestoreSystem:
    """Minimal Linux rename boundary used only on retained directory FDs."""

    @staticmethod
    def exchange_between(first_parent, first, second_parent, second):
        if sys.platform != "linux":
            raise ComponentRestorePlanError()
        libc = ctypes.CDLL(None, use_errno=True)
        renameat2 = getattr(libc, "renameat2", None)
        if renameat2 is None:
            raise ComponentRestorePlanError()
        renameat2.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        renameat2.restype = ctypes.c_int
        if (
            renameat2(
                first_parent,
                first.encode(),
                second_parent,
                second.encode(),
                2,
            )
            != 0
        ):
            raise ComponentRestorePlanError()

    @staticmethod
    def move(first_parent, first, second_parent, second):
        if sys.platform != "linux":
            raise ComponentRestorePlanError()
        libc = ctypes.CDLL(None, use_errno=True)
        renameat2 = getattr(libc, "renameat2", None)
        if renameat2 is None:
            raise ComponentRestorePlanError()
        renameat2.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        renameat2.restype = ctypes.c_int
        if (
            renameat2(
                first_parent,
                first.encode(),
                second_parent,
                second.encode(),
                1,
            )
            != 0
        ):
            raise ComponentRestorePlanError()


class LinuxRestoreFileLease:
    """Private retained root and same-filesystem recovery artifacts."""

    def __init__(
        self,
        source,
        target,
        parent,
        root,
        target_name,
        stage_name,
        rollback_name,
        trash_name,
        root_identity,
    ):
        self.source = source
        self.target = target
        self.parent = parent
        self.root = root
        self.target_name = target_name
        self.stage_name = stage_name
        self.rollback_name = rollback_name
        self.trash_name = trash_name
        self.root_identity = root_identity
        self.stage_identity = None
        self.trash_identity = None
        self.rollback = None
        self.stage = None

    def __repr__(self):
        return "LinuxRestoreFileLease(<private>)"


def _write_private(parent, name, payload):
    descriptor = -1
    created = False
    try:
        descriptor = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=parent,
        )
        created = True
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset : offset + 64 * 1024])
            if written <= 0:
                raise ComponentRestorePlanError()
            offset += written
        os.fchmod(descriptor, 0o600)
        os.fsync(descriptor)
    except Exception:
        if descriptor >= 0:
            _close(descriptor)
            descriptor = -1
        if created:
            try:
                os.unlink(name, dir_fd=parent)
                os.fsync(parent)
            except OSError:
                pass
        raise ComponentRestorePlanError() from None
    finally:
        if descriptor >= 0:
            _close(descriptor)
    os.fsync(parent)


def _read_private(parent, name):
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=parent,
    )
    try:
        info = os.fstat(descriptor)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_nlink != 1
            or stat.S_IMODE(info.st_mode) != 0o600
            or not 1 <= info.st_size <= MAX_COMPONENT_VOLUME_BYTES
        ):
            raise ComponentRestorePlanError()
        chunks = []
        remaining = info.st_size
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                raise ComponentRestorePlanError()
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise ComponentRestorePlanError()
        return b"".join(chunks)
    finally:
        _close(descriptor)


def _clear_directory(descriptor, deadline):
    names = os.listdir(descriptor)
    if len(names) > 4096:
        raise ComponentRestorePlanError()
    for name in names:
        _active(deadline)
        info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode):
            _remove_tree(descriptor, name, deadline)
        elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
            os.unlink(name, dir_fd=descriptor)
        else:
            raise ComponentRestorePlanError()
    os.fsync(descriptor)


class LinuxDirectoryRestoreEngine:
    """Publish child entries atomically while retaining the volume-root inode."""

    def __init__(self, *, system=None):
        selected = system or LinuxRestoreSystem()
        if any(
            not callable(getattr(selected, name, None))
            for name in ("exchange_between", "move")
        ):
            raise ComponentRestorePlanError()
        self._system = selected

    @staticmethod
    def _names(operation_id, index):
        prefix = f".larenor-restore-{operation_id}-{index:03d}"
        return prefix, f"{prefix}.rollback", f"{prefix}.trash"

    def acquire(self, pairs, operation_id, deadline):
        leases = []
        try:
            if (
                type(pairs) is not tuple
                or not 1 <= len(pairs) <= 128
                or type(operation_id) is not str
                or len(operation_id) != 32
                or any(char not in "0123456789abcdef" for char in operation_id)
            ):
                raise ComponentRestorePlanError()
            for index, pair in enumerate(pairs):
                _active(deadline)
                if (
                    type(pair) is not tuple
                    or len(pair) != 2
                    or type(pair[0]) is not ComponentVolumeSource
                    or type(pair[1]) is not ComponentRestoreVolumeTarget
                ):
                    raise ComponentRestorePlanError()
                source, target = pair
                if (
                    source.volume_id != target.volume_id
                    or source.installation_revision != target.binding_revision
                ):
                    raise ComponentRestorePlanError()
                parent = -1
                root = -1
                try:
                    before = source.path.lstat()
                    parent = os.open(
                        source.path.parent,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    )
                    root = os.open(
                        source.path.name,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                        dir_fd=parent,
                    )
                    current = os.fstat(root)
                    after = source.path.lstat()
                    if (
                        not stat.S_ISDIR(current.st_mode)
                        or (before.st_dev, before.st_ino)
                        != (source.device, source.inode)
                        or (current.st_dev, current.st_ino)
                        != (source.device, source.inode)
                        or (after.st_dev, after.st_ino) != (source.device, source.inode)
                        or os.fstat(parent).st_dev != current.st_dev
                    ):
                        raise ComponentRestorePlanError()
                    stage_name, rollback_name, trash_name = self._names(
                        operation_id, index
                    )
                    leases.append(
                        LinuxRestoreFileLease(
                            source,
                            target,
                            parent,
                            root,
                            source.path.name,
                            stage_name,
                            rollback_name,
                            trash_name,
                            (current.st_dev, current.st_ino),
                        )
                    )
                    parent = -1
                    root = -1
                finally:
                    if root >= 0:
                        _close(root)
                    if parent >= 0:
                        _close(parent)
            return tuple(leases)
        except ComponentRestorePlanError:
            self.close(leases)
            raise
        except Exception:
            self.close(leases)
            raise ComponentRestorePlanError() from None

    @staticmethod
    def capture_rollback(lease, deadline):
        if type(lease) is not LinuxRestoreFileLease:
            raise ComponentRestorePlanError()
        payload = archive_component_directory(lease.root, deadline)
        _write_private(lease.parent, lease.rollback_name, payload)
        lease.rollback = (len(payload), hashlib.sha256(payload).hexdigest())
        return lease.rollback

    @staticmethod
    def stage(lease, payload, deadline):
        if (
            type(lease) is not LinuxRestoreFileLease
            or type(payload) is not bytes
            or lease.rollback is None
        ):
            raise ComponentRestorePlanError()
        created = False
        try:
            os.mkdir(lease.stage_name, 0o700, dir_fd=lease.parent)
            created = True
            stage = os.open(
                lease.stage_name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=lease.parent,
            )
            try:
                _extract_archive(payload, stage, deadline)
                lease.stage = _directory_digest(stage, deadline)
                info = os.fstat(stage)
                lease.stage_identity = (info.st_dev, info.st_ino)
            finally:
                _close(stage)
            os.fsync(lease.parent)
            expected = (len(payload), hashlib.sha256(payload).hexdigest())
            if lease.stage != expected:
                raise ComponentRestorePlanError()
            return lease.stage
        except Exception:
            if created:
                try:
                    _remove_tree(lease.parent, lease.stage_name, deadline)
                except Exception:
                    pass
            lease.stage = None
            lease.stage_identity = None
            raise ComponentRestorePlanError() from None

    @staticmethod
    def _root_current(lease, deadline):
        info = os.fstat(lease.root)
        current = os.stat(lease.target_name, dir_fd=lease.parent, follow_symlinks=False)
        if (
            not stat.S_ISDIR(info.st_mode)
            or (info.st_dev, info.st_ino) != lease.root_identity
            or (current.st_dev, current.st_ino) != lease.root_identity
        ):
            raise ComponentRestorePlanError()
        return _directory_digest(lease.root, deadline)

    @staticmethod
    def _stage_current(lease, deadline):
        descriptor = os.open(
            lease.stage_name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=lease.parent,
        )
        try:
            info = os.fstat(descriptor)
            if (info.st_dev, info.st_ino) != lease.stage_identity:
                raise ComponentRestorePlanError()
            return _directory_digest(descriptor, deadline)
        finally:
            _close(descriptor)

    def revalidate(self, leases, deadline):
        try:
            for lease in leases:
                root = self._root_current(lease, deadline)
                if root == lease.rollback:
                    if self._stage_current(lease, deadline) != lease.stage:
                        return False
                elif root != lease.stage:
                    return False
            return True
        except Exception:
            return False

    def commit(self, lease, deadline):
        if self._root_current(lease, deadline) == lease.stage:
            return True
        if (
            self._root_current(lease, deadline) != lease.rollback
            or self._stage_current(lease, deadline) != lease.stage
        ):
            raise ComponentRestorePlanError()
        os.mkdir(lease.trash_name, 0o700, dir_fd=lease.parent)
        trash = os.open(
            lease.trash_name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=lease.parent,
        )
        stage = os.open(
            lease.stage_name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=lease.parent,
        )
        try:
            old_names = set(os.listdir(lease.root))
            new_names = set(os.listdir(stage))
            if len(old_names | new_names) > 4096:
                raise ComponentRestorePlanError()
            for name in sorted(old_names | new_names):
                _active(deadline)
                if name in old_names and name in new_names:
                    self._system.exchange_between(lease.root, name, stage, name)
                elif name in new_names:
                    self._system.move(stage, name, lease.root, name)
                else:
                    self._system.move(lease.root, name, trash, name)
                os.fsync(lease.root)
                os.fsync(stage)
                os.fsync(trash)
            os.fsync(lease.parent)
        finally:
            _close(stage)
            _close(trash)
        if self._root_current(lease, deadline) != lease.stage:
            raise ComponentRestorePlanError()
        return True

    def _restore_rollback(self, lease, deadline):
        payload = _read_private(lease.parent, lease.rollback_name)
        if (len(payload), hashlib.sha256(payload).hexdigest()) != lease.rollback:
            raise ComponentRestorePlanError()
        _clear_directory(lease.root, deadline)
        _extract_archive(payload, lease.root, deadline)
        if self._root_current(lease, deadline) != lease.rollback:
            raise ComponentRestorePlanError()

    def rollback(self, lease, deadline):
        if lease.stage is None:
            if self._root_current(lease, deadline) != lease.rollback:
                raise ComponentRestorePlanError()
            payload = _read_private(lease.parent, lease.rollback_name)
            if (len(payload), hashlib.sha256(payload).hexdigest()) != lease.rollback:
                raise ComponentRestorePlanError()
            for name in (lease.stage_name, lease.trash_name):
                try:
                    _remove_tree(lease.parent, name, deadline)
                except FileNotFoundError:
                    pass
            os.unlink(lease.rollback_name, dir_fd=lease.parent)
            os.fsync(lease.parent)
            return True
        self._restore_rollback(lease, deadline)
        for name in (lease.stage_name, lease.trash_name):
            try:
                _remove_tree(lease.parent, name, deadline)
            except FileNotFoundError:
                pass
        os.unlink(lease.rollback_name, dir_fd=lease.parent)
        os.fsync(lease.parent)
        return True

    def finalize(self, lease, deadline):
        if self._root_current(lease, deadline) != lease.stage:
            raise ComponentRestorePlanError()
        for name in (lease.stage_name, lease.trash_name):
            try:
                _remove_tree(lease.parent, name, deadline)
            except FileNotFoundError:
                pass
        os.unlink(lease.rollback_name, dir_fd=lease.parent)
        os.fsync(lease.parent)
        return True

    @staticmethod
    def close(leases):
        for lease in leases:
            _close(lease.root)
            _close(lease.parent)

    def recover(self, pairs, operation_id, rollbacks, stages, deadline):
        leases = self.acquire(pairs, operation_id, deadline)
        try:
            staged_by_resource = {item.resource_id: item for item in stages}
            if len(leases) != len(rollbacks) or len(staged_by_resource) != len(stages):
                raise ComponentRestorePlanError()
            for lease, rollback in zip(leases, rollbacks, strict=True):
                staged = staged_by_resource.get(lease.target.resource_id)
                if (
                    type(rollback) is not ComponentRestoreRollbackReceipt
                    or rollback.resource_id != lease.target.resource_id
                ):
                    raise ComponentRestorePlanError()
                lease.rollback = (rollback.byte_length, rollback.sha256)
                payload = _read_private(lease.parent, lease.rollback_name)
                if (
                    len(payload),
                    hashlib.sha256(payload).hexdigest(),
                ) != lease.rollback:
                    raise ComponentRestorePlanError()
                if staged is not None:
                    if type(staged) is not ComponentRestoreStageReceipt:
                        raise ComponentRestorePlanError()
                    lease.stage = (staged.byte_length, staged.sha256)
                    stage = os.open(
                        lease.stage_name,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                        dir_fd=lease.parent,
                    )
                    try:
                        info = os.fstat(stage)
                        lease.stage_identity = (info.st_dev, info.st_ino)
                    finally:
                        _close(stage)
            return leases
        except Exception:
            self.close(leases)
            raise ComponentRestorePlanError() from None


class LinuxComponentRestoreSession:
    """One authority-bound quiesce/stage/exchange session."""

    def __init__(
        self,
        plan,
        operation_id,
        sources,
        controller,
        engine,
        *,
        leases=None,
        adopted_pauses=(),
        deadline=None,
    ):
        self._plan = plan
        self._operation_id = operation_id
        self._sources = sources
        self._controller = controller
        self._engine = engine
        self._leases = leases
        self._adopted_pauses = list(adopted_pauses)
        self._rolled_back = False
        self._released = False
        self._deadline = deadline

    def _volume_pairs(self, volumes):
        by_resource = {
            lease.target.resource_id: lease for lease in (self._leases or ())
        }
        try:
            result = tuple(by_resource[item.resource_id] for item in volumes)
        except Exception:
            raise ComponentRestorePlanError() from None
        if len(result) != len(volumes):
            raise ComponentRestorePlanError()
        return result

    def quiesce(self, targets, deadline):
        if targets != self._plan.targets or self._adopted_pauses:
            raise ComponentRestorePlanError()
        container_ids = tuple(sorted({item.container_id for item in self._sources}))
        for container_id in container_ids:
            if self._controller.pause(container_id, deadline) is not True:
                raise ComponentRestorePlanError()
            self._adopted_pauses.append(container_id)
        return True

    def paused_containers(self):
        paused = tuple(sorted(self._adopted_pauses))
        if paused != tuple(sorted(set(paused))):
            raise ComponentRestorePlanError()
        return paused

    def capture_rollback(self, volume, deadline):
        lease = self._volume_pairs((volume,))[0]
        byte_length, sha256 = self._engine.capture_rollback(lease, deadline)
        return ComponentRestoreRollbackReceipt(
            resource_id=volume.resource_id,
            binding_id=volume.binding_id,
            binding_revision=volume.binding_revision,
            receipt_id=_digest(
                {
                    "operationId": self._operation_id,
                    "resourceId": volume.resource_id,
                    "bindingId": volume.binding_id,
                    "bindingRevision": volume.binding_revision,
                    "byteLength": byte_length,
                    "sha256": sha256,
                }
            ),
            byte_length=byte_length,
            sha256=sha256,
        )

    def stage(self, volume, payload, rollback, deadline):
        lease = self._volume_pairs((volume,))[0]
        byte_length, sha256 = self._engine.stage(lease, payload, deadline)
        return ComponentRestoreStageReceipt(
            resource_id=volume.resource_id,
            binding_id=volume.binding_id,
            binding_revision=volume.binding_revision,
            rollback_receipt_id=rollback.receipt_id,
            stage_id=_digest(
                {
                    "operationId": self._operation_id,
                    "resourceId": volume.resource_id,
                    "rollbackReceiptId": rollback.receipt_id,
                    "byteLength": byte_length,
                    "sha256": sha256,
                }
            ),
            byte_length=byte_length,
            sha256=sha256,
        )

    def revalidate(self, plan, deadline):
        if plan != self._plan or not self._controller.revalidate_restore_sources(
            self._sources, deadline
        ):
            return False
        return self._leases is None or self._engine.revalidate(self._leases, deadline)

    def commit(self, stages, rollbacks, deadline):
        if self._leases is None or len(stages) != len(rollbacks):
            raise ComponentRestorePlanError()
        for lease in self._volume_pairs(stages):
            self._engine.commit(lease, deadline)
        return True

    def _recover_leases(self, rollbacks, stages, deadline):
        if self._leases is not None or not rollbacks:
            return
        targets = {
            item.resource_id: item
            for target in self._plan.targets
            for item in target.volumes
        }
        sources = {f"component-{item.volume_id}": item for item in self._sources}
        pairs = tuple(
            (sources[item.resource_id], targets[item.resource_id]) for item in rollbacks
        )
        self._leases = self._engine.recover(
            pairs,
            self._operation_id,
            tuple(rollbacks),
            tuple(stages),
            deadline,
        )

    def rollback(self, rollbacks, stages, deadline=None):
        if deadline is None:
            deadline = self._deadline
        container_ids = tuple(sorted({item.container_id for item in self._sources}))
        for container_id in container_ids:
            if container_id in self._adopted_pauses:
                continue
            if self._controller.pause(container_id, deadline) is not True:
                raise ComponentRestorePlanError()
            self._adopted_pauses.append(container_id)
        self._recover_leases(rollbacks, stages, deadline)
        for lease in reversed(self._leases or ()):
            if lease.rollback is not None:
                self._engine.rollback(lease, deadline)
        self._rolled_back = True
        return True

    def release(self):
        if self._released:
            return True
        deadline = self._deadline
        for container_id in reversed(self._adopted_pauses):
            if self._controller.unpause(container_id, deadline) is not True:
                raise ComponentRestorePlanError()
        self._adopted_pauses.clear()
        self._released = True
        if self._rolled_back:
            self._engine.close(self._leases or ())
        return True

    def finalize(self, rollbacks, stages, deadline=None):
        if not self._released:
            raise ComponentRestorePlanError()
        if deadline is None:
            deadline = self._deadline
        self._recover_leases(rollbacks, stages, deadline)
        for lease in self._leases or ():
            self._engine.finalize(lease, deadline)
        self._engine.close(self._leases or ())
        return True


class LinuxComponentRestoreBoundary:
    """Explicitly enabled production bridge from Docker authority to host FDs."""

    def __init__(self, authority, controller, engine, *, enabled=False):
        if (
            enabled is not True
            or type(authority) is not DurableComponentRestoreAuthority
            or type(controller) is not UnixDockerComponentSnapshotAdapter
            or type(engine) is not LinuxDirectoryRestoreEngine
        ):
            raise ComponentRestorePlanError()
        self._authority = authority
        self._controller = controller
        self._engine = engine

    def _pairs(self, plan, sources):
        if type(plan) is not ComponentRestorePlan:
            raise ComponentRestorePlanError()
        authority = {item.service_id: item for item in self._authority.snapshot()}
        planned = {item.service_id: item for item in plan.targets}
        source_map = {(item.service_id, item.volume_id): item for item in sources}
        if set(authority) != set(planned):
            raise ComponentRestorePlanError()
        pairs = []
        for service_id in sorted(planned):
            expected = authority[service_id]
            target = planned[service_id]
            if (
                target.installation_id != expected.installation_id
                or target.installation_revision != expected.installation_revision
                or target.service_version != expected.service_version
                or target.config_schema_version != expected.config_schema_version
                or target.data_schema_version != expected.data_schema_version
            ):
                raise ComponentRestorePlanError()
            authority_volumes = {item.volume_id: item for item in expected.volumes}
            for volume in target.volumes:
                authority_volume = authority_volumes.get(volume.volume_id)
                source = source_map.get((service_id, volume.volume_id))
                if (
                    authority_volume is None
                    or source is None
                    or volume.binding_id != authority_volume.binding_id
                    or volume.binding_revision != authority_volume.binding_revision
                ):
                    raise ComponentRestorePlanError()
                pairs.append((source, volume))
        if len(pairs) != len(sources):
            raise ComponentRestorePlanError()
        return tuple(pairs)

    def acquire_durable(self, plan, operation_id, deadline):
        try:
            sources = self._controller.sources(deadline)
            pairs = self._pairs(plan, sources)
            leases = self._engine.acquire(pairs, operation_id, deadline)
            return LinuxComponentRestoreSession(
                plan,
                operation_id,
                sources,
                self._controller,
                self._engine,
                leases=leases,
                deadline=deadline,
            )
        except ComponentRestorePlanError:
            raise
        except Exception:
            raise ComponentRestorePlanError() from None

    def recover_durable(self, plan, operation_id, paused_containers, deadline):
        try:
            sources, paused = self._controller.restore_sources(deadline)
            self._pairs(plan, sources)
            planned = tuple(sorted({item.container_id for item in sources}))
            if (
                type(paused_containers) is not tuple
                or paused_containers != tuple(sorted(set(paused_containers)))
                or paused_containers not in ((), planned)
                or any(item not in planned for item in paused)
                or not paused_containers
                and paused
            ):
                raise ComponentRestorePlanError()
            adopted = tuple(item for item in paused if item in paused_containers)
            if adopted != paused:
                raise ComponentRestorePlanError()
            if self._controller.adopt_restore_pauses(adopted, deadline) is not True:
                raise ComponentRestorePlanError()
            return LinuxComponentRestoreSession(
                plan,
                operation_id,
                sources,
                self._controller,
                self._engine,
                adopted_pauses=adopted,
                deadline=deadline,
            )
        except ComponentRestorePlanError:
            raise
        except Exception:
            raise ComponentRestorePlanError() from None
