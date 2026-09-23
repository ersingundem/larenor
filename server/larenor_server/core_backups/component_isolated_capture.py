"""Authority-bound leases for isolated read-only component captures.

The native capture engine owns the atomic filesystem operation.  This module
accepts only an exact, separately rooted, read-only descriptor set bound to the
durable installation source tuple and keeps that lease alive through the
consumer boundary.
"""

import fcntl
import math
import os
import re
import stat
import time
from contextlib import contextmanager
from dataclasses import dataclass, fields

from .component_snapshot_provider import ComponentVolumeSource

_CAPTURE_ID = re.compile(r"[a-z0-9][a-z0-9_.-]{0,127}\Z")


class IsolatedComponentCaptureError(RuntimeError):
    """Static capture failure without host paths or backend diagnostics."""

    def __init__(self):
        super().__init__("isolated_capture_unavailable")


@dataclass(frozen=True, repr=False)
class IsolatedComponentVolume:
    service_id: str
    container_id: str
    volume_id: str
    service_version: str
    config_schema_version: int
    data_schema_version: str
    installation_revision: int
    source_device: int
    source_inode: int
    snapshot_device: int
    snapshot_inode: int
    descriptor: int
    writer_container_ids: tuple[str, ...]
    capture_version: int
    capture_id: str

    def __repr__(self):
        return "IsolatedComponentVolume(<private>)"


def _exact(value, cls):
    return type(value) is cls and set(vars(value)) == {
        item.name for item in fields(cls)
    }


def _remaining(deadline):
    if (
        type(deadline) not in (int, float)
        or type(deadline) is bool
        or not math.isfinite(deadline)
        or deadline - time.monotonic() <= 0
    ):
        raise IsolatedComponentCaptureError()


class AuthorityBoundIsolatedCapture:
    """Validate and own one native read-only/COW capture lease."""

    def __init__(self, engine):
        if any(
            not hasattr(engine, name) or not callable(getattr(engine, name))
            for name in ("capture", "revalidate", "release")
        ):
            raise IsolatedComponentCaptureError()
        self._engine = engine

    @staticmethod
    def _validate(sources, capture):
        if (
            type(sources) not in (tuple, list)
            or type(capture) not in (tuple, list)
            or not sources
            or len(sources) != len(capture)
            or len(sources) > 128
        ):
            raise IsolatedComponentCaptureError()
        expected = {}
        for source in sources:
            if not _exact(source, ComponentVolumeSource):
                raise IsolatedComponentCaptureError()
            key = (source.service_id, source.volume_id)
            if key in expected:
                raise IsolatedComponentCaptureError()
            expected[key] = source

        selected = []
        capture_ids = set()
        snapshot_identities = set()
        descriptors = set()
        for value in capture:
            if not _exact(value, IsolatedComponentVolume):
                raise IsolatedComponentCaptureError()
            source = expected.get((value.service_id, value.volume_id))
            try:
                info = os.fstat(value.descriptor)
                flags = fcntl.fcntl(value.descriptor, fcntl.F_GETFL)
                fd_flags = fcntl.fcntl(value.descriptor, fcntl.F_GETFD)
            except (OSError, TypeError, ValueError):
                raise IsolatedComponentCaptureError() from None
            if (
                source is None
                or (
                    value.container_id,
                    value.service_version,
                    value.config_schema_version,
                    value.data_schema_version,
                    value.installation_revision,
                    value.source_device,
                    value.source_inode,
                )
                != (
                    source.container_id,
                    source.service_version,
                    source.config_schema_version,
                    source.data_schema_version,
                    source.installation_revision,
                    source.device,
                    source.inode,
                )
                or type(value.descriptor) is not int
                or value.descriptor < 0
                or not stat.S_ISDIR(info.st_mode)
                or (info.st_dev, info.st_ino)
                != (value.snapshot_device, value.snapshot_inode)
                or (value.snapshot_device, value.snapshot_inode)
                == (value.source_device, value.source_inode)
                or flags & os.O_ACCMODE != os.O_RDONLY
                or not fd_flags & fcntl.FD_CLOEXEC
                or value.writer_container_ids != (value.container_id,)
                or type(value.capture_version) is not int
                or value.capture_version != 1
                or type(value.capture_id) is not str
                or _CAPTURE_ID.fullmatch(value.capture_id) is None
                or value.capture_id in capture_ids
                or (value.snapshot_device, value.snapshot_inode)
                in snapshot_identities
                or value.descriptor in descriptors
            ):
                raise IsolatedComponentCaptureError()
            capture_ids.add(value.capture_id)
            snapshot_identities.add((value.snapshot_device, value.snapshot_inode))
            descriptors.add(value.descriptor)
            selected.append(value)
        if set(expected) != {
            (item.service_id, item.volume_id) for item in selected
        }:
            raise IsolatedComponentCaptureError()
        return tuple(sorted(selected, key=lambda item: (item.service_id, item.volume_id)))

    @contextmanager
    def acquire(self, sources, deadline):
        _remaining(deadline)
        capture = None
        active_error = False
        try:
            try:
                ordered = tuple(
                    sorted(sources, key=lambda item: (item.service_id, item.volume_id))
                )
                capture = self._engine.capture(ordered, deadline)
                selected = self._validate(ordered, capture)
                _remaining(deadline)
                if self._engine.revalidate(selected, deadline) is not True:
                    raise IsolatedComponentCaptureError()
            except IsolatedComponentCaptureError:
                raise
            except Exception:
                raise IsolatedComponentCaptureError() from None
            yield selected
            _remaining(deadline)
            try:
                if self._engine.revalidate(selected, deadline) is not True:
                    raise IsolatedComponentCaptureError()
            except IsolatedComponentCaptureError:
                raise
            except Exception:
                raise IsolatedComponentCaptureError() from None
        except BaseException:
            active_error = True
            raise
        finally:
            release_failed = False
            if capture is not None:
                try:
                    release_deadline = time.monotonic() + 2
                    if self._engine.release(capture, release_deadline) is not True:
                        release_failed = True
                except Exception:
                    release_failed = True
            if release_failed and not active_error:
                raise IsolatedComponentCaptureError()
