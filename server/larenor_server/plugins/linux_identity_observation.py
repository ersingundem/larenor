"""Bounded read-only credentials/maps for a private held process-directory FD.

The standalone capture inspects its caller-supplied descriptor; arbitrary
directory contents are NOT authenticated kernel/process provenance. Only the
optional existing ContextLease integration supplies socket-pidfd/proc binding.
Neither form proves a native supervisor, initial host namespace, remap-disabled
daemon startup, container-to-host mapping, or permission to create/chown/write.

uid_map/gid_map depend on the opener's user namespace; both target and opener
namespace descriptors remain held. Equal maps are not initial-namespace proof.
https://man7.org/linux/man-pages/man7/user_namespaces.7.html
No namespace entry, process discovery, Docker call, or numeric-pidfd fallback.
"""

from dataclasses import dataclass
import math
import os
from pathlib import Path
import re
import stat
import sys
import threading
import time


MAX_PROC_BYTES = 16384
MAX_MAP_ROWS = 340
_MAX_ID = 2**32 - 1  # This ID itself is deliberately unmapped by Linux.
_PROC_ROOT = Path('/proc')
_DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


class IdentityObservationError(Exception):
    """Only a static diagnostic; never proc data, path or credentials."""

    def __init__(self, code='identity_observation_unavailable'):
        super().__init__(code if code == 'identity_observation_busy' else 'identity_observation_unavailable')


_ERRORS = (OSError, ValueError, TypeError, AttributeError, RuntimeError, OverflowError, IdentityObservationError)


def _require(value):
    if not value:
        raise IdentityObservationError() from None


def _guard(deadline, event):
    _require(type(deadline) in (int, float) and 0 < deadline < float('inf')
             and math.isfinite(deadline) and time.monotonic() < deadline and not event.is_set())


def _close(fd):
    try:
        os.close(fd)
    except OSError:
        pass  # Retrying could close an unrelated reused descriptor.


@dataclass(frozen=True, repr=False)
class IdMapExtent:
    inside_first: int
    outside_first: int
    length: int


def parse_id_map(raw):
    """Preserve bounded nonoverlapping extents; infer no host mapping policy."""
    _require(type(raw) is bytes and 0 < len(raw) <= MAX_PROC_BYTES and raw.endswith(b'\n'))
    lines = raw[:-1].split(b'\n')
    _require(1 <= len(lines) <= MAX_MAP_ROWS)
    records = []
    for line in lines:
        match = re.fullmatch(rb'[ \t]*(0|[1-9][0-9]{0,9})[ \t]+(0|[1-9][0-9]{0,9})[ \t]+(0|[1-9][0-9]{0,9})[ \t]*', line)
        _require(match is not None)
        inside, outside, count = (int(value) for value in match.groups())
        _require(count > 0 and inside + count <= _MAX_ID and outside + count <= _MAX_ID)
        records.append(IdMapExtent(inside, outside, count))
    for attribute in ('inside_first', 'outside_first'):
        intervals = sorted((getattr(item, attribute), item.length) for item in records)
        _require(all(left + count <= right for (left, count), (right, _) in zip(intervals, intervals[1:])))
    return tuple(records)


def _read(proc, name, deadline, event):
    _guard(deadline, event)
    fd = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=proc)
    try:
        _require(stat.S_ISREG(os.fstat(fd).st_mode))
        data = bytearray()
        while len(data) <= MAX_PROC_BYTES:
            _guard(deadline, event)
            part = os.read(fd, min(4096, MAX_PROC_BYTES + 1 - len(data)))
            _guard(deadline, event)
            if not part:
                _require(bool(data) and data.endswith(b'\n'))
                return bytes(data)
            data.extend(part)
        _require(False)
    finally:
        _close(fd)


def _start(raw, pid):
    end = raw.rfind(b')')
    _require(raw.startswith(str(pid).encode() + b' (') and end > 0)
    fields = raw[end + 1:].split()
    _require(len(fields) >= 20 and fields[0] not in (b'Z', b'X', b'x')
             and re.fullmatch(rb'0|[1-9][0-9]{0,19}', fields[19]) is not None)
    value = int(fields[19])
    _require(value <= 2**64 - 1)
    return value


def _credentials(raw):
    result = []
    for name in (b'Uid:', b'Gid:'):
        matching = [line.split()[1:] for line in raw.splitlines() if line.startswith(name)]
        _require(len(matching) == 1 and len(matching[0]) == 4)
        _require(all(re.fullmatch(rb'0|[1-9][0-9]{0,9}', part) is not None for part in matching[0]))
        values = tuple(int(part) for part in matching[0])
        _require(all(value < _MAX_ID for value in values))
        result.append(values)
    return tuple(result)


def _identity(fd, *, directory=False):
    info = os.fstat(fd)
    _require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))
    return info.st_dev, info.st_ino


def _namespace(proc, handles, deadline, event):
    _guard(deadline, event)
    # Fixed procfs magic link: following is intentional. No input path is used.
    fd = os.open('ns/user', os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=proc)
    handles.append(fd)
    return _identity(fd)


def _take(proc, pid, deadline, event):
    handles = []
    try:
        _guard(deadline, event)
        owner = os.getpid(), threading.get_native_id()
        opener = os.open(_PROC_ROOT / str(owner[0]) / 'task' / str(owner[1]), _DIRECTORY_FLAGS)
        handles.append(opener)
        opener_identity = _identity(opener, directory=True)
        opener_start = _start(_read(opener, 'stat', deadline, event), owner[1])
        opener_namespace = _namespace(opener, handles, deadline, event)
        proc_identity = _identity(proc, directory=True)
        start = _start(_read(proc, 'stat', deadline, event), pid)
        target_namespace = _namespace(proc, handles, deadline, event)
        credentials = _credentials(_read(proc, 'status', deadline, event))
        maps = []
        for name in ('uid_map', 'gid_map'):
            maps.append(tuple((item.inside_first, item.outside_first, item.length)
                              for item in parse_id_map(_read(proc, name, deadline, event))))
        _require(_namespace(proc, handles, deadline, event) == target_namespace)
        _require(_namespace(opener, handles, deadline, event) == opener_namespace)
        _require(_start(_read(proc, 'stat', deadline, event), pid) == start
                 and _credentials(_read(proc, 'status', deadline, event)) == credentials
                 and _start(_read(opener, 'stat', deadline, event), owner[1]) == opener_start)
        _require(_identity(proc, directory=True) == proc_identity
                 and (os.getpid(), threading.get_native_id()) == owner)
        _guard(deadline, event)
        return (pid, start, proc_identity, owner, opener_identity, opener_start, *credentials,
                *maps, target_namespace, opener_namespace), handles
    except BaseException:
        for fd in reversed(handles):
            _close(fd)
        raise


@dataclass(frozen=True, repr=False)
class ProcessIdentitySnapshot:
    pid: int
    start_time: int
    proc_identity: tuple[int, int]
    opener: tuple[int, int]
    opener_proc_identity: tuple[int, int]
    opener_start_time: int
    uids: tuple[int, int, int, int]
    gids: tuple[int, int, int, int]
    uid_map: tuple[IdMapExtent, ...]
    gid_map: tuple[IdMapExtent, ...]
    target_user_namespace: tuple[int, int]
    opener_user_namespace: tuple[int, int]


class HeldProcessIdentity:
    """Private borrowed-FD facts; check does not authenticate FD provenance.

    Namespace handles and a duplicate proc FD are owned until close/failure.
    Only the originating process/native thread can recheck these observations.
    No callback can assert success and no boolean represents mapping authority.
    """

    def __init__(self, proc, pid, expected, handles, event):
        self._proc, self._pid, self._expected = proc, pid, expected
        self._handles, self._event = [proc, *handles], event
        self._owner = os.getpid(), threading.get_native_id()
        self._mutex = threading.Lock()

    def __repr__(self):
        return 'HeldProcessIdentity(<private>)'

    @property
    def snapshot(self):
        # Return fresh nested records: unsafe local mutation cannot alter the
        # immutable primitive baseline used by check.
        values = list(self._expected)
        values[8:10] = [tuple(IdMapExtent(*item) for item in rows) for rows in values[8:10]]
        return ProcessIdentitySnapshot(*values)

    def _dispose(self):
        handles, self._handles = self._handles, []
        self._proc = -1
        for fd in reversed(handles):
            _close(fd)

    def check(self, deadline):
        if not self._mutex.acquire(blocking=False):
            raise IdentityObservationError('identity_observation_busy') from None
        fresh = []
        try:
            _guard(deadline, self._event)
            _require(sys.platform == 'linux' and self._proc >= 0
                     and self._owner == (os.getpid(), threading.get_native_id()))
            deadline = min(deadline, time.monotonic() + 2)
            value, fresh = _take(self._proc, self._pid, deadline, self._event)
            _require(value == self._expected)
            _guard(deadline, self._event)
        except _ERRORS:
            self._dispose()
            raise IdentityObservationError() from None
        finally:
            for fd in reversed(fresh):
                _close(fd)
            self._mutex.release()

    def close(self):
        if not self._mutex.acquire(blocking=False):
            raise IdentityObservationError('identity_observation_busy') from None
        try:
            self._dispose()
        finally:
            self._mutex.release()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def capture_process_identity(proc_fd, *, pid, deadline, cancelled=None):
    """Inspect a private descriptor; only ContextLease supplies provenance.

    Linux 6.1-compatible proc reads, at most 16 KiB each and 340 map extents.
    Deadlines bound reads/checks, not a kernel filesystem syscall stuck forever.
    """
    proc, handles, held = -1, [], None
    try:
        _require(sys.platform == 'linux' and type(proc_fd) is int and proc_fd >= 0
                 and type(pid) is int and 0 < pid < 2**31
                 and (cancelled is None or type(cancelled) is threading.Event))
        event = threading.Event() if cancelled is None else cancelled
        _guard(deadline, event)
        deadline = min(deadline, time.monotonic() + 2)
        proc = os.dup(proc_fd)
        os.set_inheritable(proc, False)
        _identity(proc, directory=True)
        expected, handles = _take(proc, pid, deadline, event)
        held = HeldProcessIdentity(proc, pid, expected, handles, event)
        proc, handles = -1, []
        held.check(deadline)
        return held
    except _ERRORS:
        if held is not None:
            held.close()
        raise IdentityObservationError() from None
    finally:
        for fd in reversed(handles):
            _close(fd)
        if proc >= 0:
            _close(proc)
