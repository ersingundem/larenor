"""Linux component restore boundaries bound to durable installation receipts."""

import hashlib
import io
import json
import math
import os
import stat
import sys
import time
import zipfile

import ctypes

from .component_installation_authority import (
    DurableComponentInstallationAuthority,
)
from .component_restore import (
    ComponentRestoreAuthorityTarget,
    ComponentRestoreAuthorityVolume,
    ComponentRestorePlanError,
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
    """Minimal Linux syscall boundary; tests inject only atomic exchange."""

    @staticmethod
    def exchange(parent, first, second):
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
        if renameat2(parent, first.encode(), parent, second.encode(), 2) != 0:
            raise ComponentRestorePlanError()


class LinuxRestoreFileLease:
    """Private retained root and same-filesystem stage identity."""

    def __init__(
        self,
        source,
        target,
        parent,
        root,
        target_name,
        stage_name,
        root_identity,
    ):
        self.source = source
        self.target = target
        self.parent = parent
        self.root = root
        self.target_name = target_name
        self.stage_name = stage_name
        self.root_identity = root_identity
        self.stage_identity = None
        self.rollback = None
        self.stage = None

    def __repr__(self):
        return "LinuxRestoreFileLease(<private>)"


class LinuxDirectoryRestoreEngine:
    """Stage and exchange component trees through retained directory FDs."""

    def __init__(self, *, system=None):
        selected = system or LinuxRestoreSystem()
        if not callable(getattr(selected, "exchange", None)):
            raise ComponentRestorePlanError()
        self._system = selected

    def acquire(self, pairs, operation_id, deadline):
        leases = []
        try:
            if (
                type(pairs) is not tuple
                or not 1 <= len(pairs) <= 128
                or type(operation_id) is not str
                or len(operation_id) != 32
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
                before = source.path.lstat()
                parent = os.open(
                    source.path.parent,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                )
                try:
                    root = os.open(
                        source.path.name,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                        dir_fd=parent,
                    )
                except Exception:
                    _close(parent)
                    raise
                current = os.fstat(root)
                after = source.path.lstat()
                if (
                    not stat.S_ISDIR(current.st_mode)
                    or (before.st_dev, before.st_ino) != (source.device, source.inode)
                    or (current.st_dev, current.st_ino) != (source.device, source.inode)
                    or (after.st_dev, after.st_ino) != (source.device, source.inode)
                    or os.fstat(parent).st_dev != current.st_dev
                ):
                    _close(root)
                    _close(parent)
                    raise ComponentRestorePlanError()
                stage_name = f".larenor-restore-{operation_id}-{index:03d}"
                leases.append(
                    LinuxRestoreFileLease(
                        source,
                        target,
                        parent,
                        root,
                        source.path.name,
                        stage_name,
                        (current.st_dev, current.st_ino),
                    )
                )
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
        lease.rollback = _directory_digest(lease.root, deadline)
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
            finally:
                _close(stage)
            os.fsync(lease.parent)
            opened = os.open(
                lease.stage_name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=lease.parent,
            )
            try:
                lease.stage = _directory_digest(opened, deadline)
                info = os.fstat(opened)
                lease.stage_identity = (info.st_dev, info.st_ino)
            finally:
                _close(opened)
            expected = (len(payload), hashlib.sha256(payload).hexdigest())
            if lease.stage != expected:
                raise ComponentRestorePlanError()
            return lease.stage
        except ComponentRestorePlanError:
            if created:
                try:
                    _remove_tree(lease.parent, lease.stage_name, deadline)
                except Exception:
                    pass
            lease.stage = None
            lease.stage_identity = None
            raise
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
    def _current(lease, deadline):
        target = os.open(
            lease.target_name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=lease.parent,
        )
        stage = os.open(
            lease.stage_name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=lease.parent,
        )
        try:
            target_info = os.fstat(target)
            stage_info = os.fstat(stage)
            return (
                (
                    _directory_digest(target, deadline),
                    (target_info.st_dev, target_info.st_ino),
                ),
                (
                    _directory_digest(stage, deadline),
                    (stage_info.st_dev, stage_info.st_ino),
                ),
            )
        finally:
            _close(target)
            _close(stage)

    def revalidate(self, leases, deadline):
        try:
            return all(
                self._current(lease, deadline)
                in {
                    self._pending(lease),
                    self._committed(lease),
                }
                for lease in leases
            )
        except Exception:
            return False

    @staticmethod
    def _pending(lease):
        return (
            (lease.rollback, lease.root_identity),
            (lease.stage, lease.stage_identity),
        )

    @staticmethod
    def _committed(lease):
        return (
            (lease.stage, lease.stage_identity),
            (lease.rollback, lease.root_identity),
        )

    def commit(self, lease, deadline):
        if self._current(lease, deadline) == self._committed(lease):
            return True
        if self._current(lease, deadline) != self._pending(lease):
            raise ComponentRestorePlanError()
        self._system.exchange(lease.parent, lease.target_name, lease.stage_name)
        os.fsync(lease.parent)
        if self._current(lease, deadline) != self._committed(lease):
            raise ComponentRestorePlanError()
        return True

    def rollback(self, lease, deadline):
        current = self._current(lease, deadline)
        if current == self._committed(lease):
            self._system.exchange(lease.parent, lease.target_name, lease.stage_name)
            os.fsync(lease.parent)
        elif current != self._pending(lease):
            raise ComponentRestorePlanError()
        if self._current(lease, deadline) != self._pending(lease):
            raise ComponentRestorePlanError()
        _remove_tree(lease.parent, lease.stage_name, deadline)
        return True

    @staticmethod
    def finalize(lease, deadline):
        if LinuxDirectoryRestoreEngine._current(
            lease, deadline
        ) != LinuxDirectoryRestoreEngine._committed(lease):
            raise ComponentRestorePlanError()
        _remove_tree(lease.parent, lease.stage_name, deadline)
        return True

    @staticmethod
    def close(leases):
        for lease in leases:
            _close(lease.root)
            _close(lease.parent)
