"""Private, read-only observation of an exact operator-approved data root.

Open actual '/' and every named directory using O_NOFOLLOW/dir_fd. Keep all
parents alive and recheck both the held objects and their current named links.
Real Linux mount observations bind each descriptor to this native thread's
mount namespace and process root. A separate disk on the approved path is
allowed only as an observed, stable mount transition at that exact component.
No subtree is inspected: mounts below the selected root are not assessed.

This is NOT an AppdataRootLease, supervisor anchor, daemon/map proof, resource
reservation or write grant. A borrowed directory descriptor is a private OS
capability, not a read-only security sandbox; only trusted in-process readers
may receive it. No API/IPC serialization or effect dispatcher exists here.
The original HostPolicy object is revalidated, not a replaced global policy.

Bounded path depth and cooperative deadlines limit work; they cannot interrupt
a filesystem syscall stalled in the kernel. Later changes by privileged actors
remain possible after the last observation. Linux 6.1 mount evidence does not
provide the separate SO_PEERPIDFD/supervisor prerequisites of a native issuer.
"""

from contextlib import contextmanager
from copy import deepcopy
from dataclasses import fields
import math
import os
import re
import stat
import sys
import threading
import time

from .host_preflight import HostPolicy, HostRoot
from .linux_mount_observation import MountObservation, MountObservationError, observe_fd_mount


MAX_PATH_BYTES = 4096
MAX_PATH_COMPONENTS = 128
_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
_ROOT = re.compile(r'[a-z][a-z0-9_-]{0,39}\Z')
_ERRORS = (OSError, ValueError, TypeError, AttributeError, RuntimeError,
           OverflowError, MountObservationError)


class RootObservationError(Exception):
    def __init__(self, code='root_observation_unavailable'):
        super().__init__(code if code == 'root_observation_busy' else 'root_observation_unavailable')


def _require(condition):
    if not condition:
        raise ValueError()


def _close(fd):
    try:
        os.close(fd)
    except OSError:
        # A failed close is never retried after the number might be reused.
        pass


def _guard(deadline, event):
    _require(type(deadline) in (int, float) and math.isfinite(deadline)
             and time.monotonic() < deadline and not event.is_set())


def _policy(policy, root_id):
    _require(type(policy) is HostPolicy and set(vars(policy)) == {f.name for f in fields(HostPolicy)})
    _require(type(root_id) is str and _ROOT.fullmatch(root_id) is not None)
    # Re-run existing strict constructors; copied/frozen objects are not proof
    # that the caller has preserved their invariants since policy loading.
    checked = HostPolicy(policy.roots, policy.owner_uid, policy.docker)
    _require(checked.owner_uid == os.geteuid())
    for root in checked.roots.values():
        _require(set(vars(root)) == {f.name for f in fields(HostRoot)} and type(root.path) is str)
        HostRoot(root.path, root.purpose)
    selected = checked.roots.get(root_id)
    _require(selected is not None and selected.purpose == 'data')
    encoded = selected.path.encode('utf-8')
    parts = selected.path.split('/')[1:]
    _require(1 < len(encoded) <= MAX_PATH_BYTES and 1 <= len(parts) <= MAX_PATH_COMPONENTS
             and all(1 <= len(part.encode('utf-8')) <= 255 for part in parts))
    return selected.path, checked.owner_uid, tuple(parts)


def _identity(fd, owner_uid):
    value = os.fstat(fd)
    _require(stat.S_ISDIR(value.st_mode) and value.st_uid in {0, owner_uid}
             and not value.st_mode & 0o022)
    return value.st_dev, value.st_ino, value.st_uid, value.st_gid, stat.S_IMODE(value.st_mode)


def _mount(fd, owner_uid, deadline, event):
    _guard(deadline, event)
    identity = _identity(fd, owner_uid)
    value = observe_fd_mount(fd, deadline=deadline)
    _guard(deadline, event)
    _require(type(value) is MountObservation and value.directory_identity == identity
             and _identity(fd, owner_uid) == identity and not value.idmapped)
    return value


class HeldAppdataRoot:
    """Live named-path facts; constructed only by observe_appdata_root.

    Keep this object on its original native thread. A failed check permanently
    closes the observation. Private borrowed_root is for trusted readers only.
    """

    def __init__(self, policy, root_id, expected, handles, mounts, event):
        self._policy, self._root_id, self._expected = policy, root_id, expected
        self._handles, self._mounts, self._event = handles, mounts, event
        self._owner = os.getpid(), threading.get_native_id()
        self._mutex = threading.Lock()

    def __repr__(self):
        return 'HeldAppdataRoot(<private>)'

    @property
    def root_identity(self):
        return self._mounts[-1].directory_identity

    @property
    def mount(self):
        # Facts returned to a private caller must not alias held expectations.
        return deepcopy(self._mounts[-1])

    def _dispose(self):
        handles, self._handles = self._handles, []
        for fd in reversed(handles):
            _close(fd)

    def _check(self, deadline):
        _guard(deadline, self._event)
        _require(sys.platform == 'linux' and self._handles
                 and self._owner == (os.getpid(), threading.get_native_id())
                 and _policy(self._policy, self._root_id) == self._expected)
        deadline = min(deadline, time.monotonic() + 2)
        _, uid, parts = self._expected
        fresh = []
        try:
            # A fresh complete walk sees overmounts that fstat on a pinned old
            # descriptor (or st_dev/st_ino alone) would otherwise miss.
            for index, held in enumerate(self._handles):
                _guard(deadline, self._event)
                _require(_mount(held, uid, deadline, self._event) == self._mounts[index])
                fd = os.open('/' if index == 0 else parts[index - 1], _FLAGS,
                             **({} if index == 0 else {'dir_fd': fresh[-1]}))
                fresh.append(fd)
                _require(_mount(fd, uid, deadline, self._event) == self._mounts[index])
            # Re-open every held parent->name link after the forward walk.
            # Earlier parents renamed during a later open cannot be accepted.
            for index in reversed(range(len(self._handles))):
                _guard(deadline, self._event)
                fd = os.open('/' if index == 0 else parts[index - 1], _FLAGS,
                             **({} if index == 0 else {'dir_fd': self._handles[index - 1]}))
                try:
                    _require(_mount(fd, uid, deadline, self._event) == self._mounts[index])
                finally:
                    _close(fd)
            _require(self._owner == (os.getpid(), threading.get_native_id())
                     and _policy(self._policy, self._root_id) == self._expected)
            _guard(deadline, self._event)
        finally:
            for fd in reversed(fresh):
                _close(fd)

    @contextmanager
    def borrowed_root(self, deadline):
        """Private descriptor access, checked before/after; never a write grant."""
        if not self._mutex.acquire(blocking=False):
            raise RootObservationError('root_observation_busy') from None
        try:
            self._check(deadline)
            yield self._handles[-1]
            self._check(deadline)
        except _ERRORS:
            self._dispose()
            raise RootObservationError() from None
        except BaseException:
            self._dispose()
            raise
        finally:
            self._mutex.release()

    def check(self, deadline):
        with self.borrowed_root(deadline):
            pass

    def close(self):
        if not self._mutex.acquire(blocking=False):
            raise RootObservationError('root_observation_busy') from None
        try:
            self._dispose()
        finally:
            self._mutex.release()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def observe_appdata_root(policy, root_id, *, deadline, cancelled=None):
    """Resolve one exact data root from actual '/', with retained path/mount FDs.

    No fallback to a nearest existing parent, symlink or sticky-temp exception.
    A selected readonly mount is rejected; readonly ancestors are observations
    and may lead to a separately mounted writable approved disk.
    """
    handles, held = [], None
    try:
        _require(sys.platform == 'linux' and (cancelled is None or type(cancelled) is threading.Event))
        event = threading.Event() if cancelled is None else cancelled
        _guard(deadline, event)
        deadline = min(deadline, time.monotonic() + 2)
        expected = _policy(policy, root_id)
        _, uid, parts = expected
        owner = os.getpid(), threading.get_native_id()
        mounts = []
        for index in range(len(parts) + 1):
            _guard(deadline, event)
            fd = os.open('/' if index == 0 else parts[index - 1], _FLAGS,
                         **({} if index == 0 else {'dir_fd': handles[-1]}))
            handles.append(fd)
            value = _mount(fd, uid, deadline, event)
            if index == 0:
                _require((*value.directory_identity, value.mount_id) == value.process_root_identity
                         and value.mount.mount_point == '/')
            else:
                _require(value.namespace_identity == mounts[0].namespace_identity
                         and value.process_root_identity == mounts[0].process_root_identity)
                parent = mounts[-1]
                if value.mount_id != parent.mount_id:
                    _require(value.mount.parent_id == parent.mount_id
                             and value.mount.mount_point == '/' + '/'.join(parts[:index]))
                else:
                    _require(value.mount == parent.mount)
            mounts.append(value)
        _require(not mounts[-1].read_only and owner == (os.getpid(), threading.get_native_id()))
        held = HeldAppdataRoot(policy, root_id, expected, handles, tuple(mounts), event)
        handles = []
        held.check(deadline)
        return held
    except _ERRORS:
        if held is not None:
            held.close()
        raise RootObservationError() from None
    except BaseException:
        if held is not None:
            held.close()
        raise
    finally:
        for fd in reversed(handles):
            _close(fd)
