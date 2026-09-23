"""Bounded read-only snapshots for catalog-managed component volumes.

The required installed authority must prove the paused managed container is the
only volume writer for the complete context. A hostile host administrator or a
shared out-of-band writer requires a native read-only/COW snapshot and is not a
claim of this portable filesystem boundary.
"""

import io
import math
import os
import re
import stat
import sys
import time
import zipfile
from contextlib import contextmanager
from dataclasses import dataclass, fields
from pathlib import Path

from ..errors import StartupError
from ..files import checked_path
from ..plugins.catalog import load_catalog
from .models import MAX_COMPONENT_BYTES, MAX_COMPONENT_VOLUME_BYTES
from .service import ComponentVolumeSnapshot

_CONTAINER_ID = re.compile(r"[a-z0-9][a-z0-9_.-]{0,127}\Z")
_VOLUME_ID = re.compile(r"[a-z][a-z0-9-]{0,127}\Z")
_OPEN_DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
_OPEN_FILE = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
_MAX_ENTRIES = 10_000
_MAX_DEPTH = 32


class ComponentSnapshotProviderError(RuntimeError):
    """Static host-provider failure without paths or controller details."""

    def __init__(self, code="snapshot_unavailable"):
        self.code = (
            code
            if code
            in {
                "invalid_snapshot_configuration",
                "snapshot_unavailable",
                "snapshot_too_large",
            }
            else "snapshot_unavailable"
        )
        super().__init__(self.code)


@dataclass(frozen=True, repr=False)
class ComponentVolumeSource:
    service_id: str
    container_id: str
    volume_id: str
    path: Path
    service_version: str
    config_schema_version: int
    data_schema_version: str
    installation_revision: int
    device: int
    inode: int


def _exact(value, cls):
    return type(value) is cls and set(vars(value)) == {
        item.name for item in fields(cls)
    }


def _remaining(deadline):
    if (
        type(deadline) not in (int, float)
        or type(deadline) is bool
        or not math.isfinite(deadline)
    ):
        raise ComponentSnapshotProviderError()
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ComponentSnapshotProviderError()
    return remaining


def _safe_name(value):
    return (
        type(value) is str
        and 1 <= len(value.encode("utf-8", "strict")) <= 255
        and value not in {".", ".."}
        and "/" not in value
        and not any(
            ord(char) < 32
            or ord(char) == 127
            or 0xD800 <= ord(char) <= 0xDFFF
            for char in value
        )
    )


def _fingerprint(info):
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_uid,
        info.st_gid,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def _bounded_directory_names(parent, deadline, limit, *, overflow_code):
    names = []
    try:
        with os.scandir(parent) as entries:
            for entry in entries:
                _remaining(deadline)
                name = entry.name
                if not _safe_name(name):
                    raise ComponentSnapshotProviderError()
                names.append(name)
                if len(names) > limit:
                    raise ComponentSnapshotProviderError(overflow_code)
    except ComponentSnapshotProviderError:
        raise
    except (OSError, TypeError, UnicodeError, ValueError):
        raise ComponentSnapshotProviderError() from None
    return sorted(names)


def _zip_info(name, mode, *, directory):
    info = zipfile.ZipInfo(name + ("/" if directory else ""))
    info.date_time = (1980, 1, 1, 0, 0, 0)
    info.create_system = 3
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = ((stat.S_IFDIR if directory else stat.S_IFREG) | mode) << 16
    return info


def archive_component_directory(
    descriptor,
    deadline,
    *,
    max_bytes=MAX_COMPONENT_VOLUME_BYTES,
):
    """Archive one held directory without following links or special files."""
    if (
        type(descriptor) is not int
        or descriptor < 0
        or type(max_bytes) is not int
        or not 1 <= max_bytes <= MAX_COMPONENT_VOLUME_BYTES
    ):
        raise ComponentSnapshotProviderError("invalid_snapshot_configuration")
    _remaining(deadline)
    try:
        root = os.dup(descriptor)
        os.set_inheritable(root, False)
        if not stat.S_ISDIR(os.fstat(root).st_mode):
            raise OSError()
    except (OSError, TypeError, ValueError):
        raise ComponentSnapshotProviderError() from None

    output = io.BytesIO()
    count = 0
    total = 0
    inventory = {}

    def check_output():
        if output.tell() > max_bytes:
            raise ComponentSnapshotProviderError("snapshot_too_large")

    def visit(parent, prefix, depth, archive):
        nonlocal count, total
        if depth > _MAX_DEPTH:
            raise ComponentSnapshotProviderError("snapshot_unavailable")
        _remaining(deadline)
        before_names = _bounded_directory_names(
            parent,
            deadline,
            _MAX_ENTRIES - count,
            overflow_code="snapshot_too_large",
        )
        observed = {}
        for name in before_names:
            _remaining(deadline)
            count += 1
            relative = f"{prefix}/{name}" if prefix else name
            before = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if stat.S_ISDIR(before.st_mode):
                child = os.open(name, _OPEN_DIRECTORY, dir_fd=parent)
                try:
                    opened = os.fstat(child)
                    if _fingerprint(opened) != _fingerprint(before):
                        raise ComponentSnapshotProviderError()
                    archive.writestr(
                        _zip_info(
                            relative,
                            stat.S_IMODE(opened.st_mode),
                            directory=True,
                        ),
                        b"",
                    )
                    check_output()
                    visit(child, relative, depth + 1, archive)
                    after = os.stat(name, dir_fd=parent, follow_symlinks=False)
                    if (
                        _fingerprint(after) != _fingerprint(opened)
                        or _fingerprint(os.fstat(child)) != _fingerprint(opened)
                    ):
                        raise ComponentSnapshotProviderError()
                    observed[name] = _fingerprint(after)
                    inventory[relative] = observed[name]
                finally:
                    os.close(child)
            elif stat.S_ISREG(before.st_mode) and before.st_nlink == 1:
                child = os.open(name, _OPEN_FILE, dir_fd=parent)
                try:
                    opened = os.fstat(child)
                    if (
                        not stat.S_ISREG(opened.st_mode)
                        or opened.st_nlink != 1
                        or _fingerprint(opened) != _fingerprint(before)
                    ):
                        raise ComponentSnapshotProviderError()
                    total += opened.st_size
                    if total > max_bytes:
                        raise ComponentSnapshotProviderError("snapshot_too_large")
                    payload = bytearray()
                    while len(payload) < opened.st_size:
                        _remaining(deadline)
                        part = os.read(
                            child,
                            min(64 * 1024, opened.st_size - len(payload)),
                        )
                        if not part:
                            raise ComponentSnapshotProviderError()
                        payload.extend(part)
                    if os.read(child, 1):
                        raise ComponentSnapshotProviderError()
                    after = os.stat(name, dir_fd=parent, follow_symlinks=False)
                    if (
                        _fingerprint(after) != _fingerprint(opened)
                        or _fingerprint(os.fstat(child)) != _fingerprint(opened)
                    ):
                        raise ComponentSnapshotProviderError()
                    observed[name] = _fingerprint(after)
                    inventory[relative] = observed[name]
                    try:
                        archive.writestr(
                            _zip_info(
                                relative,
                                stat.S_IMODE(opened.st_mode),
                                directory=False,
                            ),
                            payload,
                        )
                        check_output()
                    finally:
                        payload[:] = b"\0" * len(payload)
                finally:
                    os.close(child)
            else:
                raise ComponentSnapshotProviderError()
        _remaining(deadline)
        if (
            _bounded_directory_names(
                parent,
                deadline,
                len(before_names),
                overflow_code="snapshot_unavailable",
            )
            != before_names
        ):
            raise ComponentSnapshotProviderError()
        for name in before_names:
            current = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if _fingerprint(current) != observed[name]:
                raise ComponentSnapshotProviderError()

    def revalidate_tree(parent, prefix, depth, seen):
        if depth > _MAX_DEPTH:
            raise ComponentSnapshotProviderError()
        _remaining(deadline)
        names = _bounded_directory_names(
            parent,
            deadline,
            len(inventory) - len(seen),
            overflow_code="snapshot_unavailable",
        )
        for name in names:
            relative = f"{prefix}/{name}" if prefix else name
            current = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if relative in seen or _fingerprint(current) != inventory.get(relative):
                raise ComponentSnapshotProviderError()
            seen.add(relative)
            if stat.S_ISDIR(current.st_mode):
                child = os.open(name, _OPEN_DIRECTORY, dir_fd=parent)
                try:
                    if _fingerprint(os.fstat(child)) != inventory[relative]:
                        raise ComponentSnapshotProviderError()
                    revalidate_tree(child, relative, depth + 1, seen)
                    after = os.stat(name, dir_fd=parent, follow_symlinks=False)
                    if (
                        _fingerprint(after) != inventory[relative]
                        or _fingerprint(os.fstat(child)) != inventory[relative]
                    ):
                        raise ComponentSnapshotProviderError()
                finally:
                    os.close(child)
            elif not stat.S_ISREG(current.st_mode):
                raise ComponentSnapshotProviderError()

    try:
        with zipfile.ZipFile(
            output,
            mode="w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=6,
            allowZip64=False,
        ) as archive:
            visit(root, "", 0, archive)
            seen = set()
            revalidate_tree(root, "", 0, seen)
            if seen != set(inventory):
                raise ComponentSnapshotProviderError()
        value = output.getvalue()
        _remaining(deadline)
        if not value or len(value) > max_bytes:
            raise ComponentSnapshotProviderError("snapshot_too_large")
        return value
    except ComponentSnapshotProviderError:
        raise
    except (
        OSError,
        OverflowError,
        RuntimeError,
        UnicodeError,
        ValueError,
        zipfile.LargeZipFile,
    ):
        raise ComponentSnapshotProviderError() from None
    finally:
        os.close(root)


def _open_absolute_directory(path):
    descriptors = []
    try:
        parent = os.open("/", _OPEN_DIRECTORY)
        descriptors.append(parent)
        for part in path.parts[1:]:
            child = os.open(part, _OPEN_DIRECTORY, dir_fd=parent)
            descriptors.append(child)
            parent = child
        result = os.dup(parent)
        os.set_inheritable(result, False)
        return result
    except OSError:
        raise ComponentSnapshotProviderError() from None
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


class ManagedComponentSnapshotProvider:
    """Pause sole-writer managed containers and snapshot complete appdata."""

    def __init__(
        self,
        sources,
        controller,
        installed_authority,
        *,
        isolated_capture=None,
        monotonic=time.monotonic,
    ):
        try:
            if (
                type(sources) not in (tuple, list)
                or len(sources) > 128
                or not hasattr(controller, "pause")
                or not callable(controller.pause)
                or not hasattr(controller, "unpause")
                or not callable(controller.unpause)
                or not hasattr(installed_authority, "revalidate")
                or not callable(installed_authority.revalidate)
                or isolated_capture is not None
                and (
                    not hasattr(isolated_capture, "acquire")
                    or not callable(isolated_capture.acquire)
                )
                or not callable(monotonic)
            ):
                raise ValueError()
            catalog = {}
            for entry in load_catalog().entries:
                manifest = entry.manifest
                catalog[manifest.serviceId] = (
                    manifest,
                    {
                        f"{manifest.serviceId}-{mount.relativePath.rsplit('/', 1)[-1]}"
                        for mount in manifest.mounts
                        if mount.kind == "managed_appdata"
                    },
                )
            selected = []
            seen = set()
            paths = set()
            identities = set()
            grouped = {}
            containers = {}
            container_services = {}
            for value in sources:
                if not _exact(value, ComponentVolumeSource):
                    raise ValueError()
                path = Path(value.path)
                checked_path(path)
                info = path.lstat()
                identity = (value.service_id, value.volume_id)
                path_identity = (info.st_dev, info.st_ino)
                expected_manifest = catalog.get(value.service_id, (None, set()))[0]
                if (
                    expected_manifest is None
                    or type(value.container_id) is not str
                    or _CONTAINER_ID.fullmatch(value.container_id) is None
                    or type(value.volume_id) is not str
                    or _VOLUME_ID.fullmatch(value.volume_id) is None
                    or value.volume_id not in catalog[value.service_id][1]
                    or type(value.service_version) is not str
                    or value.service_version != expected_manifest.version
                    or type(value.config_schema_version) is not int
                    or value.config_schema_version
                    != expected_manifest.configSchemaVersion
                    or type(value.data_schema_version) is not str
                    or value.data_schema_version
                    != expected_manifest.dataSchemaVersion
                    or type(value.installation_revision) is not int
                    or not 1 <= value.installation_revision <= 2**63 - 1
                    or type(value.device) is not int
                    or value.device < 0
                    or type(value.inode) is not int
                    or value.inode <= 0
                    or path_identity != (value.device, value.inode)
                    or identity in seen
                    or path in paths
                    or path_identity in identities
                    or not stat.S_ISDIR(info.st_mode)
                    or any(
                        ord(char) < 32 or ord(char) == 127 for char in str(path)
                    )
                ):
                    raise ValueError()
                previous = containers.setdefault(
                    value.service_id, value.container_id
                )
                if previous != value.container_id:
                    raise ValueError()
                previous_service = container_services.setdefault(
                    value.container_id, value.service_id
                )
                if previous_service != value.service_id:
                    raise ValueError()
                seen.add(identity)
                paths.add(path)
                identities.add(path_identity)
                grouped.setdefault(value.service_id, set()).add(value.volume_id)
                selected.append(
                    ComponentVolumeSource(
                        value.service_id,
                        value.container_id,
                        value.volume_id,
                        path,
                        value.service_version,
                        value.config_schema_version,
                        value.data_schema_version,
                        value.installation_revision,
                        value.device,
                        value.inode,
                    )
                )
            ordered_paths = sorted(paths, key=str)
            if any(
                left in right.parents or right in left.parents
                for index, left in enumerate(ordered_paths)
                for right in ordered_paths[index + 1 :]
            ):
                raise ValueError()
            if any(grouped[service] != catalog[service][1] for service in grouped):
                raise ValueError()
            self.sources = tuple(
                sorted(selected, key=lambda item: (item.service_id, item.volume_id))
            )
            self.controller = controller
            self.installed_authority = installed_authority
            self.isolated_capture = isolated_capture
            self.monotonic = monotonic
        except (
            OSError,
            ValueError,
            TypeError,
            AttributeError,
            RuntimeError,
            StartupError,
        ):
            raise ComponentSnapshotProviderError(
                "invalid_snapshot_configuration"
            ) from None

    @staticmethod
    def _snapshot(source, descriptor, deadline):
        payload = archive_component_directory(descriptor, deadline)
        return ComponentVolumeSnapshot(
            serviceId=source.service_id,
            serviceVersion=source.service_version,
            configSchemaVersion=source.config_schema_version,
            dataSchemaVersion=source.data_schema_version,
            volumeId=source.volume_id,
            payload=payload,
        )

    def _capture(self, source, deadline):
        descriptor = _open_absolute_directory(source.path)
        try:
            before = os.fstat(descriptor)
            if (before.st_dev, before.st_ino) != (source.device, source.inode):
                raise ComponentSnapshotProviderError()
            snapshot = self._snapshot(source, descriptor, deadline)
            replacement = _open_absolute_directory(source.path)
            try:
                after = os.fstat(replacement)
                if (
                    (after.st_dev, after.st_ino)
                    != (source.device, source.inode)
                    or (after.st_dev, after.st_ino)
                    != (before.st_dev, before.st_ino)
                ):
                    raise ComponentSnapshotProviderError()
            finally:
                os.close(replacement)
        finally:
            os.close(descriptor)
        return snapshot

    def _capture_isolated(self, deadline):
        captured = []
        total = 0
        with self.isolated_capture.acquire(self.sources, deadline) as leases:
            selected = {
                (item.service_id, item.volume_id): item for item in leases
            }
            if len(selected) != len(leases):
                raise ComponentSnapshotProviderError()
            for source in self.sources:
                lease = selected.get((source.service_id, source.volume_id))
                if lease is None:
                    raise ComponentSnapshotProviderError()
                snapshot = self._snapshot(source, lease.descriptor, deadline)
                total += len(snapshot.payload)
                if total > MAX_COMPONENT_BYTES:
                    raise ComponentSnapshotProviderError("snapshot_too_large")
                captured.append(snapshot)
            self._revalidate(deadline)
        return tuple(captured)

    def _revalidate(self, deadline):
        try:
            _remaining(deadline)
            for source in self.sources:
                descriptor = _open_absolute_directory(source.path)
                try:
                    current = os.fstat(descriptor)
                    if (current.st_dev, current.st_ino) != (
                        source.device,
                        source.inode,
                    ):
                        raise ComponentSnapshotProviderError()
                finally:
                    os.close(descriptor)
            if self.installed_authority.revalidate(self.sources, deadline) is not True:
                raise ComponentSnapshotProviderError()
            _remaining(deadline)
        except ComponentSnapshotProviderError:
            raise
        except Exception:
            raise ComponentSnapshotProviderError() from None

    @contextmanager
    def quiesce(self, deadline):
        _remaining(deadline)
        paused = []
        active_error = False
        try:
            try:
                self._revalidate(deadline)
                containers = sorted({item.container_id for item in self.sources})
                for container_id in containers:
                    _remaining(deadline)
                    paused.append(container_id)
                    if self.controller.pause(container_id, deadline) is not True:
                        raise ComponentSnapshotProviderError()
                if self.isolated_capture is not None:
                    snapshots = self._capture_isolated(deadline)
                else:
                    captured = []
                    total = 0
                    for source in self.sources:
                        snapshot = self._capture(source, deadline)
                        total += len(snapshot.payload)
                        if total > MAX_COMPONENT_BYTES:
                            raise ComponentSnapshotProviderError("snapshot_too_large")
                        captured.append(snapshot)
                    snapshots = tuple(captured)
                    self._revalidate(deadline)
            except ComponentSnapshotProviderError:
                raise
            except Exception:
                raise ComponentSnapshotProviderError() from None
            yield snapshots
            self._revalidate(deadline)
        except BaseException:
            active_error = True
            raise
        finally:
            release_failed = False
            release_deadline = self.monotonic() + 2
            for container_id in reversed(paused):
                try:
                    if self.controller.unpause(container_id, release_deadline) is not True:
                        release_failed = True
                except Exception:
                    release_failed = True
            if not active_error and not release_failed:
                try:
                    self._revalidate(release_deadline)
                except ComponentSnapshotProviderError:
                    release_failed = True
            if release_failed and not active_error and sys.exc_info()[0] is None:
                raise ComponentSnapshotProviderError()
