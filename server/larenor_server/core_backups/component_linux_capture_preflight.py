"""Exact Linux/btrfs capability evidence for isolated component capture.

The preflight performs no snapshot mutation.  It binds a private capture-root
directory descriptor to its current mount namespace and verifies the minimum
privilege required by the later native snapshot adapter.  All host failures
collapse to one source-free error.
"""

from contextlib import contextmanager
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
_HOST_UID_MAP = (0, 0, 4294967295)


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
            match for line in lines if (match := _CAPABILITY_FIELD.fullmatch(line))
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


def _read_proc_file(path, deadline, maximum):
    descriptor = -1
    try:
        _remaining(deadline)
        descriptor = os.open(
            path,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
        )
        before = _identity(os.fstat(descriptor))
        if not stat.S_ISREG(before[2]):
            raise LinuxCapturePreflightError()
        result = bytearray()
        while len(result) <= maximum:
            _remaining(deadline)
            chunk = os.read(
                descriptor,
                min(4096, maximum + 1 - len(result)),
            )
            if not chunk:
                break
            result.extend(chunk)
        _remaining(deadline)
        if len(result) > maximum or _identity(os.fstat(descriptor)) != before:
            raise LinuxCapturePreflightError()
        return bytes(result)
    except LinuxCapturePreflightError:
        raise
    except Exception:
        raise LinuxCapturePreflightError() from None
    finally:
        if descriptor >= 0:
            _close(descriptor)


def _read_proc_status(deadline):
    return _read_proc_file("/proc/thread-self/status", deadline, _MAX_STATUS_BYTES)


def parse_host_uid_map(value):
    """Accept only the initial user namespace's complete host UID map."""
    try:
        if (
            type(value) is not bytes
            or not 1 <= len(value) <= 4096
            or not value.endswith(b"\n")
            or b"\x00" in value
            or b"\r" in value
        ):
            raise ValueError()
        lines = value[:-1].split(b"\n")
        if len(lines) != 1:
            raise ValueError()
        fields = lines[0].split()
        if len(fields) != 3 or any(not field.isdigit() for field in fields):
            raise ValueError()
        result = tuple(int(field) for field in fields)
        if result != _HOST_UID_MAP:
            raise ValueError()
        return result
    except Exception:
        raise LinuxCapturePreflightError() from None


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
    def effective_uid_map(deadline):
        return parse_host_uid_map(
            _read_proc_file("/proc/thread-self/uid_map", deadline, 4096)
        )

    @staticmethod
    def user_namespace_identity(deadline):
        descriptor = -1
        try:
            _remaining(deadline)
            descriptor = os.open(
                "/proc/thread-self/ns/user",
                os.O_RDONLY | os.O_CLOEXEC,
            )
            info = os.fstat(descriptor)
            _remaining(deadline)
            if info.st_dev < 0 or info.st_ino <= 0:
                raise LinuxCapturePreflightError()
            return info.st_dev, info.st_ino
        except LinuxCapturePreflightError:
            raise
        except Exception:
            raise LinuxCapturePreflightError() from None
        finally:
            if descriptor >= 0:
                _close(descriptor)

    @staticmethod
    def open_directory(path):
        descriptor = -1
        try:
            if not isinstance(path, Path) or not path.is_absolute():
                raise OSError()
            flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
            descriptor = os.open("/", flags)
            info = os.fstat(descriptor)
            if (
                not stat.S_ISDIR(info.st_mode)
                or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) & 0o022
            ):
                raise OSError()
            parts = path.parts[1:]
            for index, part in enumerate(parts):
                if part in {"", ".", ".."}:
                    raise OSError()
                following = os.open(part, flags, dir_fd=descriptor)
                info = os.fstat(following)
                if (
                    not stat.S_ISDIR(info.st_mode)
                    or index < len(parts) - 1
                    and (info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o022)
                ):
                    _close(following)
                    raise OSError()
                _close(descriptor)
                descriptor = following
            result = descriptor
            descriptor = -1
            return result
        finally:
            if descriptor >= 0:
                _close(descriptor)

    @staticmethod
    def path_info(path):
        return path.lstat()

    @staticmethod
    def descriptor_info(descriptor):
        return os.fstat(descriptor)

    @staticmethod
    def observe_mount(descriptor, deadline):
        return observe_fd_mount(
            descriptor,
            deadline=deadline,
            allow_btrfs_device_alias=True,
        )

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
    user_namespace_device: int
    user_namespace_inode: int

    def __post_init__(self):
        values = (
            self.schema_version,
            self.capture_device,
            self.capture_inode,
            self.mount_id,
            self.namespace_device,
            self.namespace_inode,
            self.user_namespace_device,
            self.user_namespace_inode,
        )
        if (
            any(type(value) is not int for value in values)
            or self.schema_version != 1
            or self.capture_device < 0
            or self.capture_inode <= 0
            or self.mount_id <= 0
            or self.namespace_device < 0
            or self.namespace_inode <= 0
            or self.user_namespace_device < 0
            or self.user_namespace_inode <= 0
        ):
            raise LinuxCapturePreflightError()

    def __repr__(self):
        return "LinuxBtrfsCaptureCapability(<private>)"


class LinuxBtrfsCapturePreflight:
    """Prove and retain one private root for privileged btrfs snapshots."""

    _METHODS = (
        "platform_name",
        "effective_uid",
        "effective_capabilities",
        "effective_uid_map",
        "user_namespace_identity",
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
                    ord(character) < 32 or ord(character) == 127 for character in raw
                )
            ):
                raise ValueError()
            selected = system or LinuxCaptureSystem()
            if any(
                not callable(getattr(selected, name, None)) for name in self._METHODS
            ):
                raise ValueError()
        except Exception:
            raise LinuxCapturePreflightError() from None
        self.capture_root = capture_root
        self._system = selected
        self._descriptor = -1
        self._capability = None

    def _authority(self, deadline):
        _remaining(deadline)
        if self._system.platform_name() != "linux":
            raise LinuxCapturePreflightError()
        uid = self._system.effective_uid()
        capabilities = self._system.effective_capabilities(deadline)
        uid_map = self._system.effective_uid_map(deadline)
        user_namespace = self._system.user_namespace_identity(deadline)
        if (
            type(uid) is not int
            or uid != 0
            or type(capabilities) is not int
            or capabilities < 0
            or capabilities >= 2**64
            or capabilities & (1 << CAP_SYS_ADMIN) == 0
            or uid_map != _HOST_UID_MAP
            or type(user_namespace) is not tuple
            or len(user_namespace) != 2
            or any(type(value) is not int or value < 0 for value in user_namespace)
            or user_namespace[1] <= 0
        ):
            raise LinuxCapturePreflightError()
        return uid, user_namespace

    def _root_observation(self, descriptor, uid, deadline):
        current = _identity(self._system.descriptor_info(descriptor))
        observed = self._system.observe_mount(descriptor, deadline)
        expected = (
            current[0],
            current[1],
            current[3],
            current[4],
            stat.S_IMODE(current[2]),
        )
        if (
            not stat.S_ISDIR(current[2])
            or current[3] != uid
            or stat.S_IMODE(current[2]) != 0o700
            or type(observed) is not MountObservation
            or observed.directory_identity != expected
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
        return current, observed

    @staticmethod
    def _matches_capability(current, observed, user_namespace, capability):
        return (
            (current[0], current[1])
            == (capability.capture_device, capability.capture_inode)
            and observed.mount_id == capability.mount_id
            and observed.namespace_identity
            == (capability.namespace_device, capability.namespace_inode)
            and user_namespace
            == (
                capability.user_namespace_device,
                capability.user_namespace_inode,
            )
        )

    def verify(self, deadline):
        if self._descriptor >= 0:
            if self.revalidate(self._capability, deadline):
                return self._capability
            raise LinuxCapturePreflightError()
        descriptor = -1
        try:
            uid, user_namespace = self._authority(deadline)
            before = _identity(self._system.path_info(self.capture_root))
            descriptor = self._system.open_directory(self.capture_root)
            if type(descriptor) is not int or descriptor < 0:
                raise LinuxCapturePreflightError()
            current, observed = self._root_observation(descriptor, uid, deadline)
            after = _identity(self._system.path_info(self.capture_root))
            _remaining(deadline)
            if before != current or after != current:
                raise LinuxCapturePreflightError()
            capability = LinuxBtrfsCaptureCapability(
                1,
                current[0],
                current[1],
                observed.mount_id,
                observed.namespace_identity[0],
                observed.namespace_identity[1],
                user_namespace[0],
                user_namespace[1],
            )
            self._descriptor = descriptor
            self._capability = capability
            descriptor = -1
            return capability
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
        fresh = -1
        try:
            if (
                type(capability) is not LinuxBtrfsCaptureCapability
                or capability != self._capability
                or self._descriptor < 0
            ):
                return False
            uid, user_namespace = self._authority(deadline)
            retained, retained_mount = self._root_observation(
                self._descriptor, uid, deadline
            )
            before = _identity(self._system.path_info(self.capture_root))
            fresh = self._system.open_directory(self.capture_root)
            if type(fresh) is not int or fresh < 0:
                return False
            current, observed = self._root_observation(fresh, uid, deadline)
            after = _identity(self._system.path_info(self.capture_root))
            _remaining(deadline)
            return (
                before == retained == current == after
                and self._matches_capability(
                    retained, retained_mount, user_namespace, capability
                )
                and self._matches_capability(
                    current, observed, user_namespace, capability
                )
            )
        except Exception:
            return False
        finally:
            if fresh >= 0:
                try:
                    self._system.close(fresh)
                except Exception:
                    pass

    @contextmanager
    def retain_capture(self, capability, deadline):
        """Retain the exact capture-root descriptor across one mutation."""
        try:
            if not self.revalidate(capability, deadline):
                raise LinuxCapturePreflightError()
            descriptor = self._descriptor
            if descriptor < 0:
                raise LinuxCapturePreflightError()
            yield descriptor
            _remaining(deadline)
            if not self.revalidate(capability, deadline):
                raise LinuxCapturePreflightError()
        except LinuxCapturePreflightError:
            raise
        except Exception:
            raise LinuxCapturePreflightError() from None

    def _source_observation(self, descriptor, capability, deadline):
        current = _identity(self._system.descriptor_info(descriptor))
        observed = self._system.observe_mount(descriptor, deadline)
        expected = (
            current[0],
            current[1],
            current[3],
            current[4],
            stat.S_IMODE(current[2]),
        )
        if (
            not stat.S_ISDIR(current[2])
            or current[0] != capability.capture_device
            or type(observed) is not MountObservation
            or observed.directory_identity != expected
            or observed.mount.filesystem != "btrfs"
            or observed.read_only
            or observed.idmapped
            or observed.mount_id != capability.mount_id
            or observed.namespace_identity
            != (capability.namespace_device, capability.namespace_inode)
        ):
            raise LinuxCapturePreflightError()
        return current

    @contextmanager
    def retain_source(self, path, device, inode, capability, deadline):
        descriptor = -1
        fresh = -1
        try:
            raw = str(path) if isinstance(path, Path) else ""
            if (
                type(capability) is not LinuxBtrfsCaptureCapability
                or not isinstance(path, Path)
                or not path.is_absolute()
                or path == Path("/")
                or ".." in path.parts
                or not raw
                or len(raw.encode("utf-8", "strict")) > 4096
                or any(
                    ord(character) < 32 or ord(character) == 127 for character in raw
                )
                or type(device) is not int
                or device < 0
                or type(inode) is not int
                or inode <= 0
                or not self.revalidate(capability, deadline)
            ):
                raise LinuxCapturePreflightError()
            before = _identity(self._system.path_info(path))
            descriptor = self._system.open_directory(path)
            if type(descriptor) is not int or descriptor < 0:
                raise LinuxCapturePreflightError()
            current = self._source_observation(descriptor, capability, deadline)
            after = _identity(self._system.path_info(path))
            if (
                before != current
                or after != current
                or (current[0], current[1]) != (device, inode)
            ):
                raise LinuxCapturePreflightError()
            yield descriptor
            _remaining(deadline)
            if not self.revalidate(capability, deadline):
                raise LinuxCapturePreflightError()
            before = _identity(self._system.path_info(path))
            retained = self._source_observation(descriptor, capability, deadline)
            fresh = self._system.open_directory(path)
            if type(fresh) is not int or fresh < 0:
                raise LinuxCapturePreflightError()
            current = self._source_observation(fresh, capability, deadline)
            after = _identity(self._system.path_info(path))
            if (
                before != retained
                or retained != current
                or after != current
                or (current[0], current[1]) != (device, inode)
            ):
                raise LinuxCapturePreflightError()
        except LinuxCapturePreflightError:
            raise
        except Exception:
            raise LinuxCapturePreflightError() from None
        finally:
            if fresh >= 0:
                try:
                    self._system.close(fresh)
                except Exception:
                    pass
            if descriptor >= 0:
                try:
                    self._system.close(descriptor)
                except Exception:
                    pass

    def source_retained(self, path, device, inode, capability, deadline):
        try:
            with self.retain_source(path, device, inode, capability, deadline):
                pass
            return True
        except Exception:
            return False

    def close(self):
        descriptor = self._descriptor
        self._descriptor = -1
        self._capability = None
        if descriptor >= 0:
            try:
                self._system.close(descriptor)
            except Exception:
                pass
