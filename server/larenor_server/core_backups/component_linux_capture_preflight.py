"""Exact Linux/btrfs capability evidence for isolated component capture.

The preflight performs no snapshot mutation.  It binds a private capture-root
directory descriptor to its current mount namespace and verifies the minimum
privilege required by the later native snapshot adapter.  All host failures
collapse to one source-free error.
"""

from dataclasses import dataclass
import math
import os
from pathlib import Path
import re
import stat
import sys
import time

from ..plugins.linux_mount_observation import (
    MountObservation,
    observe_fd_mount,
)


CAP_SYS_ADMIN = 21
_MAX_STATUS_BYTES = 64 * 1024
_CAPABILITY_FIELD = re.compile(rb"CapEff:\t([0-9a-f]{16})\Z")


class LinuxCapturePreflightError(RuntimeError):
    """Static unsupported-host result without paths or kernel diagnostics."""

    def __init__(self):
        super().__init__("linux_capture_unavailable")


def _remaining(deadline):
    if (
        type(deadline) not in (int, float)
        or type(deadline) is bool
        or not math.isfinite(deadline)
        or time.monotonic() >= deadline
    ):
        raise LinuxCapturePreflightError()


def parse_effective_capabilities(value):
    """Parse the one canonical ``CapEff`` field from bounded proc status."""
    try:
        if (
            type(value) is not bytes
            or not 1 <= len(value) <= _MAX_STATUS_BYTES
            or not value.endswith(b"\n")
            or b"\x00" in value
            or b"\r" in value
        ):
            raise ValueError()
        lines = value[:-1].split(b"\n")
        if any(not line or len(line) > 4096 for line in lines):
            raise ValueError()
        matches = [
            match
            for line in lines
            if (match := _CAPABILITY_FIELD.fullmatch(line))
        ]
        if len(matches) != 1 or sum(line.startswith(b"CapEff:") for line in lines) != 1:
            raise ValueError()
        return int(matches[0].group(1), 16)
    except Exception:
        raise LinuxCapturePreflightError() from None


def _identity(value):
    try:
        fields = (
            value.st_dev,
            value.st_ino,
            value.st_mode,
            value.st_uid,
            value.st_gid,
        )
        if any(type(item) is not int or item < 0 for item in fields):
            raise ValueError()
        return fields
    except Exception:
        raise LinuxCapturePreflightError() from None


def _close(descriptor):
    try:
        os.close(descriptor)
    except OSError:
        # Never retry close: the integer descriptor may already be reused.
        pass


def _read_proc_status(deadline):
    descriptor = -1
    try:
        _remaining(deadline)
        descriptor = os.open(
            "/proc/self/status",
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
        )
        before = _identity(os.fstat(descriptor))
        if not stat.S_ISREG(before[2]):
            raise LinuxCapturePreflightError()
        result = bytearray()
        while len(result) <= _MAX_STATUS_BYTES:
            _remaining(deadline)
            chunk = os.read(
                descriptor,
                min(4096, _MAX_STATUS_BYTES + 1 - len(result)),
            )
            if not chunk:
                break
            result.extend(chunk)
        _remaining(deadline)
        if len(result) > _MAX_STATUS_BYTES or _identity(os.fstat(descriptor)) != before:
            raise LinuxCapturePreflightError()
        return bytes(result)
    except LinuxCapturePreflightError:
        raise
    except Exception:
        raise LinuxCapturePreflightError() from None
    finally:
        if descriptor >= 0:
            _close(descriptor)


class LinuxCaptureSystem:
    """Injectable boundary for the fixed Linux syscalls used by preflight."""

    @staticmethod
    def platform_name():
        return sys.platform

    @staticmethod
    def effective_uid():
        return os.geteuid()

    @staticmethod
    def effective_capabilities(deadline):
        return parse_effective_capabilities(_read_proc_status(deadline))

    @staticmethod
    def open_directory(path):
        return os.open(
            path,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )

    @staticmethod
    def path_info(path):
        return path.lstat()

    @staticmethod
    def descriptor_info(descriptor):
        return os.fstat(descriptor)

    @staticmethod
    def observe_mount(descriptor, deadline):
        return observe_fd_mount(descriptor, deadline=deadline)

    @staticmethod
    def close(descriptor):
        _close(descriptor)


@dataclass(frozen=True, repr=False)
class LinuxBtrfsCaptureCapability:
    schema_version: int
    capture_device: int
    capture_inode: int
    mount_id: int
    namespace_device: int
    namespace_inode: int

    def __post_init__(self):
        values = (
            self.schema_version,
            self.capture_device,
            self.capture_inode,
            self.mount_id,
            self.namespace_device,
            self.namespace_inode,
        )
        if (
            any(type(value) is not int for value in values)
            or self.schema_version != 1
            or self.capture_device < 0
            or self.capture_inode <= 0
            or self.mount_id <= 0
            or self.namespace_device < 0
            or self.namespace_inode <= 0
        ):
            raise LinuxCapturePreflightError()

    def __repr__(self):
        return "LinuxBtrfsCaptureCapability(<private>)"


class LinuxBtrfsCapturePreflight:
    """Prove one current private root can host privileged btrfs snapshots."""

    _METHODS = (
        "platform_name",
        "effective_uid",
        "effective_capabilities",
        "open_directory",
        "path_info",
        "descriptor_info",
        "observe_mount",
        "close",
    )

    def __init__(self, capture_root, *, system=None):
        try:
            if not isinstance(capture_root, Path):
                raise ValueError()
            raw = str(capture_root)
            if (
                not capture_root.is_absolute()
                or capture_root == Path("/")
                or ".." in capture_root.parts
                or not raw
                or len(raw.encode("utf-8", "strict")) > 4096
                or any(
                    ord(character) < 32 or ord(character) == 127
                    for character in raw
                )
            ):
                raise ValueError()
            selected = system or LinuxCaptureSystem()
            if any(
                not callable(getattr(selected, name, None))
                for name in self._METHODS
            ):
                raise ValueError()
        except Exception:
            raise LinuxCapturePreflightError() from None
        self.capture_root = capture_root
        self._system = selected

    def verify(self, deadline):
        descriptor = -1
        try:
            _remaining(deadline)
            if self._system.platform_name() != "linux":
                raise LinuxCapturePreflightError()
            uid = self._system.effective_uid()
            capabilities = self._system.effective_capabilities(deadline)
            if (
                type(uid) is not int
                or uid != 0
                or type(capabilities) is not int
                or capabilities < 0
                or capabilities >= 2**64
                or capabilities & (1 << CAP_SYS_ADMIN) == 0
            ):
                raise LinuxCapturePreflightError()

            before = _identity(self._system.path_info(self.capture_root))
            descriptor = self._system.open_directory(self.capture_root)
            if type(descriptor) is not int or descriptor < 0:
                raise LinuxCapturePreflightError()
            current = _identity(self._system.descriptor_info(descriptor))
            observed = self._system.observe_mount(descriptor, deadline)
            after = _identity(self._system.path_info(self.capture_root))
            _remaining(deadline)

            expected_observed = (
                current[0],
                current[1],
                current[3],
                current[4],
                stat.S_IMODE(current[2]),
            )
            if (
                before != current
                or after != current
                or not stat.S_ISDIR(current[2])
                or current[3] != uid
                or stat.S_IMODE(current[2]) != 0o700
                or type(observed) is not MountObservation
                or observed.directory_identity != expected_observed
                or observed.mount.filesystem != "btrfs"
                or observed.read_only
                or observed.idmapped
                or type(observed.mount_id) is not int
                or observed.mount_id <= 0
                or type(observed.namespace_identity) is not tuple
                or len(observed.namespace_identity) != 2
                or any(
                    type(value) is not int or value < 0
                    for value in observed.namespace_identity
                )
            ):
                raise LinuxCapturePreflightError()
            return LinuxBtrfsCaptureCapability(
                1,
                current[0],
                current[1],
                observed.mount_id,
                observed.namespace_identity[0],
                observed.namespace_identity[1],
            )
        except LinuxCapturePreflightError:
            raise
        except Exception:
            raise LinuxCapturePreflightError() from None
        finally:
            if descriptor >= 0:
                try:
                    self._system.close(descriptor)
                except Exception:
                    pass

    def revalidate(self, capability, deadline):
        if type(capability) is not LinuxBtrfsCaptureCapability:
            return False
        try:
            return self.verify(deadline) == capability
        except Exception:
            return False
