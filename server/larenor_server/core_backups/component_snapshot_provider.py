"""Bounded read-only snapshots for catalog-managed component volumes."""

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


def _exact(value, cls):
    return type(value) is cls and set(vars(value)) == {
        item.name for item in fields(cls)
    }


def _remaining(deadline):
    remaining = deadline - time.monotonic()
    if (
        type(deadline) not in (int, float)
        or type(deadline) is bool
        or not math.isfinite(deadline)
        or remaining <= 0
    ):
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

    def check_output():
        if output.tell() > max_bytes:
            raise ComponentSnapshotProviderError("snapshot_too_large")

    def visit(parent, prefix, depth, archive):
        nonlocal count, total
        if depth > _MAX_DEPTH:
            raise ComponentSnapshotProviderError("snapshot_unavailable")
        _remaining(deadline)
        before_names = sorted(os.listdir(parent))
        for name in before_names:
            _remaining(deadline)
            if not _safe_name(name):
                raise ComponentSnapshotProviderError()
            count += 1
            if count > _MAX_ENTRIES:
                raise ComponentSnapshotProviderError("snapshot_too_large")
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
        if sorted(os.listdir(parent)) != before_names:
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
    """Pause exact managed containers and snapshot their complete appdata set."""

    def __init__(self, sources, controller, *, monotonic=time.monotonic):
        try:
            if (
                type(sources) not in (tuple, list)
                or len(sources) > 128
                or not hasattr(controller, "pause")
                or not callable(controller.pause)
                or not hasattr(controller, "unpause")
                or not callable(controller.unpause)
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
            seen, paths, grouped, containers = set(), set(), {}, {}
            for value in sources:
                if not _exact(value, ComponentVolumeSource):
                    raise ValueError()
                path = Path(value.path)
                checked_path(path)
                info = path.lstat()
                identity = (value.service_id, value.volume_id)
                if (
                    value.service_id not in catalog
                    or type(value.container_id) is not str
                    or _CONTAINER_ID.fullmatch(value.container_id) is None
                    or type(value.volume_id) is not str
                    or _VOLUME_ID.fullmatch(value.volume_id) is None
                    or value.volume_id not in catalog[value.service_id][1]
                    or identity in seen
                    or path in paths
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
                seen.add(identity)
                paths.add(path)
                grouped.setdefault(value.service_id, set()).add(value.volume_id)
                selected.append(
                    ComponentVolumeSource(
                        value.service_id,
                        value.container_id,
                        value.volume_id,
                        path,
                    )
                )
            if any(grouped[service] != catalog[service][1] for service in grouped):
                raise ValueError()
            self.sources = tuple(
                sorted(selected, key=lambda item: (item.service_id, item.volume_id))
            )
            self.controller = controller
            self.monotonic = monotonic
            self._catalog = catalog
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

    def _capture(self, source, deadline):
        descriptor = _open_absolute_directory(source.path)
        try:
            before = os.fstat(descriptor)
            payload = archive_component_directory(descriptor, deadline)
            replacement = _open_absolute_directory(source.path)
            try:
                after = os.fstat(replacement)
                if (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino):
                    raise ComponentSnapshotProviderError()
            finally:
                os.close(replacement)
        finally:
            os.close(descriptor)
        manifest = self._catalog[source.service_id][0]
        return ComponentVolumeSnapshot(
            serviceId=source.service_id,
            serviceVersion=manifest.version,
            configSchemaVersion=manifest.configSchemaVersion,
            dataSchemaVersion=manifest.dataSchemaVersion,
            volumeId=source.volume_id,
            payload=payload,
        )

    @contextmanager
    def quiesce(self, deadline):
        _remaining(deadline)
        paused = []
        active_error = False
        try:
            try:
                containers = sorted({item.container_id for item in self.sources})
                for container_id in containers:
                    _remaining(deadline)
                    if self.controller.pause(container_id, deadline) is not True:
                        raise ComponentSnapshotProviderError()
                    paused.append(container_id)
                captured = []
                total = 0
                for source in self.sources:
                    snapshot = self._capture(source, deadline)
                    total += len(snapshot.payload)
                    if total > MAX_COMPONENT_BYTES:
                        raise ComponentSnapshotProviderError("snapshot_too_large")
                    captured.append(snapshot)
                snapshots = tuple(captured)
            except ComponentSnapshotProviderError:
                raise
            except Exception:
                raise ComponentSnapshotProviderError() from None
            yield snapshots
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
            if release_failed and not active_error and sys.exc_info()[0] is None:
                raise ComponentSnapshotProviderError()
