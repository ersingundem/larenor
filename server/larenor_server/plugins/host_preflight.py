"""Read-only observations for internal components of the Larenor installation.

Only worker-owned policy resolves opaque catalog root IDs to host directories.
No path, hostname or raw OS error leaves this module. An explicit operator policy
can enable the fixed read-only Docker API/platform probe. Observations neither
enable installation nor prove published ports, receiver discovery or playback.
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
from .docker_probe import DockerEndpoint, DockerProbe
from .preflight_models import PreflightCheck, PreflightResult
from .stack_plan import verify_media_stack_plan


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
    docker: DockerEndpoint | None = field(default=None, repr=False)

    def __post_init__(self):
        if (not isinstance(self.roots, Mapping) or not 0 <= len(self.roots) <= 16
                or type(self.owner_uid) is not int or not 0 <= self.owner_uid <= 2**31 - 1
                or self.docker is not None and type(self.docker) is not DockerEndpoint):
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


def _within(deadline):
    if (type(deadline) not in (int, float) or not math.isfinite(deadline)
            or time.monotonic() >= deadline):
        raise HostPreflightError('inspection_unavailable')


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

    def _fingerprint(self, root, mounts):
        """Private path identities, never a reservation or a public identifier."""
        def identity(fd):
            info = self._stat(fd)
            return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid)
        with _root_descriptor(root.path, self._policy.owner_uid, self._stat) as descriptor:
            values = [identity(descriptor)]
            for mount in mounts:
                with _managed_descriptor(descriptor, mount.relativePath, self._policy.owner_uid, self._stat) as child:
                    values.append(identity(child))
            return tuple(values)

    def _storage(self, plans, deadline):
        by_root = {}
        for index, plan in enumerate(plans):
            purposes = {}
            for setting in plan.settings:
                if setting.name in _SETTING_PURPOSES and setting.value is not None:
                    purposes.setdefault(setting.value, set()).add(_SETTING_PURPOSES[setting.name])
            for identity in {mount.rootId for mount in plan.mounts}:
                mounts = [mount for mount in plan.mounts if mount.rootId == identity]
                by_root.setdefault(identity, []).append((index, plan, mounts, purposes.get(identity)))
        before = {}
        for identity, groups in by_root.items():
            try:
                before[identity] = self._fingerprint(self._policy.roots[identity], [m for _, _, mounts, _ in groups for m in mounts])
            except Exception:
                before[identity] = None
        roots = []
        for identity in sorted(by_root):
            _within(deadline)
            groups = by_root[identity]
            root = self._policy.roots.get(identity)
            valid, facts = before[identity] is not None, []
            for index, plan, mounts, purposes in groups:
                library_view = (root is not None and root.purpose == 'library'
                    and plan.serviceId == 'jellyfin' and purposes == {'media'}
                    and len(mounts) == 1 and mounts[0].kind == 'approved_library'
                    and mounts[0].readOnly is True and mounts[0].target == '/media'
                    and mounts[0].relativePath == '')
                matches = root is not None and (purposes == {root.purpose} or library_view)
                observed, current = self._observe_root(root, mounts) if matches and valid else (False, [])
                valid = valid and observed
                facts.extend((index, plan.resources.minimumDiskMiB, identity, *fact) for fact in current)
                _within(deadline)
            roots.append([identity, valid, groups, facts])
        # A held descriptor may refer to a replaced directory. Re-open ALL names
        # after measurement before assigning its capacity to the current path.
        for row in roots:
            identity, valid, groups, facts = row
            try:
                current = self._fingerprint(self._policy.roots[identity], [m for _, _, mounts, _ in groups for m in mounts])
                row[1] = valid and current == before[identity]
            except Exception:
                row[1] = False
        result, filesystems = [], {}
        for identity, valid, groups, facts in roots:
            result.append(PreflightCheck(code='storage_root', rootId=identity, status='passed' if valid else 'failed'))
            if valid:
                for index, budget, root_id, device, available, status in facts:
                    filesystems.setdefault(device, []).append((index, budget, root_id, available, status))
            else:
                budgets = {index: plan.resources.minimumDiskMiB for index, plan, mounts, _ in groups if any(not m.readOnly for m in mounts)}
                if budgets:
                    result.append(PreflightCheck(code='storage_capacity', rootId=identity, status='unknown', requiredMiB=sum(budgets.values())))
        for facts in sorted(filesystems.values(), key=lambda items: min(item[2] for item in items)):
            # Each child once per writable filesystem. Aliased roots and
            # config/cache mounts multiply neither free space nor the budget.
            required = sum({item[0]: item[1] for item in facts}.values())
            available = min((item[3] for item in facts if item[3] is not None), default=None)
            states = {item[4] for item in facts}
            status = 'failed' if 'failed' in states else 'unknown' if 'unknown' in states else 'passed' if available >= required else 'failed'
            result.append(PreflightCheck(code='storage_capacity', rootId=min(item[2] for item in facts),
                availableMiB=available, requiredMiB=required, status=status))
        _within(deadline)
        return result

    def inspect(self, plan, *, deadline=None):
        try:
            selected = verify_plan(plan, load_catalog())
        except (ValueError, TypeError):
            raise HostPreflightError('plan_untrusted') from None
        return self._inspect((selected,), selected.catalogDigest, selected.planHash, selected.image.platform, deadline)

    def inspect_with_deadline(self, plan, deadline):
        return self.inspect(plan, deadline=deadline)

    def inspect_stack(self, plan, *, deadline=None):
        try:
            selected = verify_media_stack_plan(plan, load_catalog())
        except (ValueError, TypeError):
            raise HostPreflightError('plan_untrusted') from None
        return self._inspect(tuple(c.plan for c in selected.components), selected.catalogDigest,
                             selected.planHash, selected.platform, deadline)

    def _inspect(self, plans, catalog_digest, plan_hash, expected_platform, deadline):
        if deadline is None:
            deadline = time.monotonic() + 5
        _within(deadline)
        deadline = min(deadline, time.monotonic() + 5)
        failed = False
        try:
            timestamp = self._clock()
            if type(timestamp) not in (int, float) or not math.isfinite(timestamp):
                raise ValueError()
            checked = datetime.fromtimestamp(timestamp, timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
            actual_platform = self._platform()
        except Exception:
            failed = True
        if failed:
            raise HostPreflightError('inspection_unavailable')
        values, attempted = None, False
        def observe_storage():
            nonlocal values, attempted
            if not attempted:
                attempted = True
                try:
                    values = self._storage(plans, deadline)
                except Exception:
                    pass
            if values is None:
                raise HostPreflightError('inspection_unavailable')
            return values
        docker_status, context = 'unknown', None
        endpoint = self._policy.docker
        if endpoint is not None and actual_platform == expected_platform:
            try:
                probe = DockerProbe(endpoint)
                if getattr(endpoint, 'daemon_executable', None) is not None:
                    observation = probe.observe(expected_platform, during=observe_storage, deadline=deadline)
                    docker_status, context = observation.status, observation.context
                else:
                    docker_status = probe.inspect(expected_platform)
            except Exception:
                docker_status, context = 'unknown', None
        if type(docker_status) is not str or docker_status not in {'passed', 'failed', 'unknown'}:
            docker_status, context = 'unknown', None
        storage = observe_storage()
        result = [PreflightCheck(code='platform', status='passed' if actual_platform == expected_platform else 'failed'), *storage,
                  PreflightCheck(code='docker_engine', status=docker_status)]
        for code, attribute in (('daemon_mount_context', 'same_mount_namespace'),
                                ('daemon_network_context', 'same_network_namespace'),
                                ('daemon_root_context', 'same_process_root')):
            value = getattr(context, attribute, None)
            result.append(PreflightCheck(code=code, status='passed' if value is True else 'failed' if value is False else 'unknown'))
        result.extend(PreflightCheck(code=code, status='unknown') for code in ('port_availability', 'receiver_network'))
        _within(deadline)
        return PreflightResult(catalogDigest=catalog_digest, planHash=plan_hash, platform=expected_platform,
                               checkedAt=checked, checks=result)
