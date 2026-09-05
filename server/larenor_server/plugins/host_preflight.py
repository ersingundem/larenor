"""Read-only observations for internal components of the Larenor installation.

Only worker-owned policy resolves opaque catalog root IDs to host directories.
No path, hostname or raw OS error leaves this module. Observations neither enable
installation nor prove Docker, published ports, receiver discovery or playback.
Disk requirements are the catalog's proposed budgets, not measured app minima.
"""

from collections.abc import Mapping
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
import math
import os
from pathlib import Path
import platform
import re
import stat
import time
from types import MappingProxyType

from .catalog import load_catalog, verify_plan
from .preflight_models import PreflightCheck, PreflightResult


_ROOT_ID = re.compile(r"[a-z][a-z0-9_-]{0,39}\Z")
_PURPOSES = frozenset({"data", "library", "media", "music"})
_SETTING_PURPOSES = {"dataRootId": "data", "libraryRootId": "library",
                     "mediaRootId": "media", "musicRootId": "music"}
_MAX_MIB = 2**63 - 1


class HostPreflightError(ValueError):
    def __init__(self, code="inspection_unavailable"):
        self.code = code if code in {"invalid_policy", "plan_untrusted", "inspection_unavailable"} else "inspection_unavailable"
        super().__init__(self.code)


@dataclass(frozen=True)
class HostRoot:
    path: str = field(repr=False)
    purpose: str

    def __post_init__(self):
        value = str(self.path) if isinstance(self.path, Path) else self.path
        if (type(value) is not str or not 1 < len(value) <= 4096 or not value.startswith("/")
                or any(ord(character) < 32 or ord(character) == 127 for character in value)
                or any(part in {".", "..", ""} for part in value.split("/")[1:])
                or type(self.purpose) is not str or self.purpose not in _PURPOSES):
            raise HostPreflightError("invalid_policy")
        object.__setattr__(self, "path", value)


@dataclass(frozen=True)
class HostPolicy:
    roots: Mapping[str, HostRoot] = field(repr=False)
    owner_uid: int = field(default_factory=os.getuid)

    def __post_init__(self):
        if (not isinstance(self.roots, Mapping) or not 0 <= len(self.roots) <= 16
                or type(self.owner_uid) is not int or not 0 <= self.owner_uid <= 2**31 - 1):
            raise HostPreflightError("invalid_policy")
        copied = dict(self.roots)
        if any(type(key) is not str or not _ROOT_ID.fullmatch(key) or type(value) is not HostRoot
               for key, value in copied.items()):
            raise HostPreflightError("invalid_policy")
        object.__setattr__(self, "roots", MappingProxyType(copied))


def _host_platform():
    if platform.system() != "Linux":
        return None
    return {"x86_64": "linux/amd64", "amd64": "linux/amd64",
            "aarch64": "linux/arm64", "arm64": "linux/arm64"}.get(platform.machine().lower())


def _safe_directory(info, owner_uid, *, ancestor=False):
    if not stat.S_ISDIR(info.st_mode) or info.st_uid not in {0, owner_uid}:
        return False
    if info.st_mode & 0o022:
        # Root-owned sticky /tmp is an acceptable ancestor, never an approved
        # writable storage root or a generated component directory.
        return ancestor and info.st_uid == 0 and bool(info.st_mode & stat.S_ISVTX)
    return True


@contextmanager
def _root_descriptor(path, owner_uid, stat_provider):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    descriptor = os.open("/", flags)
    try:
        parts = path.split("/")[1:]
        if not _safe_directory(stat_provider(descriptor), owner_uid, ancestor=True):
            raise OSError()
        for index, part in enumerate(parts):
            child = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
            if not _safe_directory(stat_provider(descriptor), owner_uid, ancestor=index < len(parts) - 1):
                raise OSError()
        yield descriptor
    finally:
        os.close(descriptor)


@contextmanager
def _managed_descriptor(root, suffix, owner_uid, stat_provider):
    """Inspect existing children; missing future directories are never created."""
    descriptor = os.dup(root)
    try:
        root_device = stat_provider(root).st_dev
        for part in suffix.split("/") if suffix else ():
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                dir_fd=descriptor)
            except FileNotFoundError:
                break
            os.close(descriptor)
            descriptor = child
            info = stat_provider(descriptor)
            if not _safe_directory(info, owner_uid) or info.st_dev != root_device:
                raise OSError()
        yield descriptor
    finally:
        os.close(descriptor)


def _capacity(value):
    if (type(value.f_bavail) is not int or value.f_bavail < 0
            or type(value.f_frsize) is not int or value.f_frsize <= 0):
        return None
    available = value.f_bavail * value.f_frsize // 1048576
    return available if available <= _MAX_MIB else None


class HostInspector:
    def __init__(self, policy, *, platform_provider=None, clock=None,
                 statvfs_provider=None, stat_provider=None):
        if type(policy) is not HostPolicy:
            raise HostPreflightError("invalid_policy")
        self._policy = policy
        self._platform = _host_platform if platform_provider is None else platform_provider
        self._clock = time.time if clock is None else clock
        self._statvfs = os.fstatvfs if statvfs_provider is None else statvfs_provider
        self._stat = os.fstat if stat_provider is None else stat_provider
        if not all(callable(provider) for provider in (self._platform, self._clock, self._statvfs, self._stat)):
            raise HostPreflightError("invalid_policy")

    def _observe_root(self, root, mounts):
        facts = []
        try:
            with _root_descriptor(root.path, self._policy.owner_uid, self._stat) as descriptor:
                for mount in mounts:
                    with _managed_descriptor(descriptor, mount.relativePath, self._policy.owner_uid, self._stat) as child:
                        if mount.readOnly:
                            continue
                        info = self._stat(child)
                        try:
                            volume = self._statvfs(child)
                            available = _capacity(volume)
                            status = "passed" if available is not None else "failed"
                            if type(volume.f_flag) is not int or volume.f_flag & os.ST_RDONLY:
                                status = "failed"
                        except OSError:
                            available, status = None, "unknown"
                        facts.append((info.st_dev, available, status))
            return True, facts
        except Exception:
            # This includes malformed injected OS observations, without leaking
            # path-bearing exceptions. A failed root never contributes capacity.
            return False, []

    def inspect(self, plan):
        invalid = False
        try:
            verified = verify_plan(plan, load_catalog())
        except (ValueError, TypeError):
            invalid = True
        if invalid:
            raise HostPreflightError("plan_untrusted")
        failed = False
        try:
            timestamp = self._clock()
            if type(timestamp) not in (int, float) or not math.isfinite(timestamp):
                raise ValueError()
            checked = datetime.fromtimestamp(timestamp, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
            actual_platform = self._platform()
        except Exception:
            failed = True
        if failed:
            raise HostPreflightError("inspection_unavailable")
        checks = [PreflightCheck(code="platform", status="passed" if actual_platform == verified.image.platform else "failed")]
        purposes = {}
        for setting in verified.settings:
            if setting.name in _SETTING_PURPOSES and setting.value is not None:
                purposes.setdefault(setting.value, set()).add(_SETTING_PURPOSES[setting.name])
        filesystems = {}
        required = verified.resources.minimumDiskMiB
        for identity in sorted({mount.rootId for mount in verified.mounts}):
            mounts = [mount for mount in verified.mounts if mount.rootId == identity]
            root = self._policy.roots.get(identity)
            valid, facts = (False, []) if root is None or purposes.get(identity) != {root.purpose} else self._observe_root(root, mounts)
            checks.append(PreflightCheck(code="storage_root", status="passed" if valid else "failed", rootId=identity))
            if not valid and any(not mount.readOnly for mount in mounts):
                checks.append(PreflightCheck(code="storage_capacity", status="unknown", rootId=identity, requiredMiB=required))
            for device, available, status in facts:
                filesystems.setdefault(device, []).append((identity, available, status))
        # One proposed plan budget per distinct writable filesystem, even when
        # config/cache or multiple approved roots alias it. Different filesystems
        # each need the whole budget because the catalog does not split it yet.
        for facts in sorted(filesystems.values(), key=lambda items: min(item[0] for item in items)):
            identity = min(item[0] for item in facts)
            available = min((item[1] for item in facts if item[1] is not None), default=None)
            states = {item[2] for item in facts}
            status = "failed" if "failed" in states else "unknown" if "unknown" in states else "passed" if available >= required else "failed"
            checks.append(PreflightCheck(code="storage_capacity", status=status, rootId=identity,
                                         availableMiB=available, requiredMiB=required))
        checks.extend(PreflightCheck(code=code, status="unknown") for code in (
            "docker_engine", "port_availability", "receiver_network"))
        return PreflightResult(catalogDigest=verified.catalogDigest, planHash=verified.planHash,
                               platform=verified.image.platform, checkedAt=checked, checks=checks)
