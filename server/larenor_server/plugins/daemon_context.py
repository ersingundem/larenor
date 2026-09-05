"""Private Linux peer-context evidence; no process paths/IDs leave this module.

The operator-selected, root-owned executable is the trust anchor, not its name
or argv. SO_PEERPIDFD binds the original socket peer even across numeric PID
reuse; an older kernel or an inherited/proxied listener fails closed. No
pidfd_open fallback, namespace entry, Docker mutation or process discovery.

References:
https://docs.kernel.org/filesystems/proc.html
https://man7.org/linux/man-pages/man7/namespaces.7.html
https://man7.org/linux/man-pages/man5/proc_pid_root.5.html
https://man7.org/linux/man-pages/man5/proc_pid_fdinfo.5.html
https://github.com/torvalds/linux/commit/7b26952a91cf65ff1cc867a2382a8964d8c0ee7d
"""

from dataclasses import dataclass, field
import os
from pathlib import Path
import select
import socket
import stat
import struct
import sys
import threading
import time


_PROC_ROOT = Path('/proc')
_MAX_PROC_BYTES = 16384
_ERRORS = (OSError, ValueError, TypeError, RuntimeError, struct.error)


def _remaining(deadline):
    if time.monotonic() >= deadline:
        raise ValueError('context_unavailable')


def _close(fd):
    try:
        os.close(fd)
    except OSError:
        pass


def _file_identity(info):
    return info.st_dev, info.st_ino


def _executable_identity(info):
    return (*_file_identity(info), info.st_uid, info.st_gid, info.st_mode,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _trusted_executable(path, deadline):
    """Walk a root-owned, non-writable, symlink-free operator path with openat."""
    directory = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        parts = Path(path).parts[1:]
        if not parts:
            raise ValueError('context_unavailable')
        for index, part in enumerate(parts):
            _remaining(deadline)
            parent = os.fstat(directory)
            if parent.st_uid != 0 or parent.st_mode & 0o022:
                raise ValueError('context_unavailable')
            final = index == len(parts) - 1
            flags = (getattr(os, 'O_PATH', os.O_RDONLY) if final else os.O_RDONLY | os.O_DIRECTORY)
            child = os.open(part, flags | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory)
            _close(directory)
            directory = child
        info = os.fstat(directory)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                or info.st_mode & 0o022 or not info.st_mode & 0o111):
            raise ValueError('context_unavailable')
        _remaining(deadline)
        return info
    finally:
        _close(directory)


def _read(proc_fd, name, deadline):
    _remaining(deadline)
    fd = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=proc_fd)
    try:
        value = bytearray()
        while len(value) <= _MAX_PROC_BYTES:
            _remaining(deadline)
            part = os.read(fd, min(4096, _MAX_PROC_BYTES + 1 - len(value)))
            if not part:
                return bytes(value).decode('ascii')
            value.extend(part)
        raise ValueError('context_unavailable')
    finally:
        _close(fd)


def _start_time(proc_fd, pid, deadline):
    value = _read(proc_fd, 'stat', deadline)
    end = value.rfind(')')
    if not value.startswith(f'{pid} (') or end < 0:
        raise ValueError('context_unavailable')
    fields = value[end + 1:].split()
    # comm can contain whitespace and parentheses. Field 22 is starttime;
    # comparing state or CPU counters would reject ordinary process activity.
    if (len(fields) < 20 or fields[0] in ('Z', 'X', 'x')
            or not fields[19].isascii() or not fields[19].isdigit() or len(fields[19]) > 20):
        raise ValueError('context_unavailable')
    return int(fields[19])


def _uids(proc_fd, deadline):
    lines = [line for line in _read(proc_fd, 'status', deadline).splitlines() if line.startswith('Uid:')]
    values = lines[0].split()[1:] if len(lines) == 1 else []
    if len(values) != 4 or any(not value.isascii() or not value.isdigit() or len(value) > 10 for value in values):
        raise ValueError('context_unavailable')
    result = tuple(int(value) for value in values)
    if any(value >= 2**32 for value in result):
        raise ValueError('context_unavailable')
    return result


def _mount_id(fd, deadline):
    """Disambiguate bind mounts sharing an inode via the held root descriptor."""
    _, worker_path = _worker_process()
    directory = os.open(worker_path / 'fdinfo',
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        lines = [line for line in _read(directory, str(fd), deadline).splitlines()
                 if line.startswith('mnt_id:')]
        fields = lines[0].split() if len(lines) == 1 else []
        if (len(fields) != 2 or not fields[1].isascii() or not fields[1].isdigit()
                or len(fields[1]) > 20 or int(fields[1]) <= 0):
            raise ValueError('context_unavailable')
        return int(fields[1])
    finally:
        _close(directory)


def _pidfd_alive(fd):
    # Linux pidfds are readable when the original process exits. This is
    # intentionally a zero-time readiness check, not a PID-number lookup.
    readable, _, exceptional = select.select([fd], [], [fd], 0)
    return not readable and not exceptional


def _worker_process():
    # The callback runs on this native thread. A thread can unshare its own
    # namespace, fs root or file table; the leader's /proc/PID view is weaker.
    tid = threading.get_native_id()
    return tid, _PROC_ROOT / str(os.getpid()) / 'task' / str(tid)


@dataclass(frozen=True)
class DaemonContext:
    same_mount_namespace: bool
    same_network_namespace: bool
    same_process_root: bool


@dataclass(repr=False)
class _Snapshot:
    identity: tuple
    handles: list = field(default_factory=list)

    def close(self):
        handles, self.handles = self.handles, []
        for fd in reversed(handles):
            _close(fd)


def _snapshot(proc_fd, pid, deadline):
    result = _Snapshot(())
    try:
        start = _start_time(proc_fd, pid, deadline)
        uids = _uids(proc_fd, deadline)
        identities = []
        for name in ('exe', 'ns/mnt', 'ns/net', 'root'):
            _remaining(deadline)
            # These four procfs magic links must be followed. Held descriptors
            # also prevent their inodes/namespaces from being recycled.
            flags = (os.O_RDONLY if name.startswith('ns/') else getattr(os, 'O_PATH', os.O_RDONLY))
            fd = os.open(name, flags | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=proc_fd)
            result.handles.append(fd)
            info = os.fstat(fd)
            if name == 'root' and not stat.S_ISDIR(info.st_mode):
                raise ValueError('context_unavailable')
            if name == 'exe' and not stat.S_ISREG(info.st_mode):
                raise ValueError('context_unavailable')
            if name == 'root':
                identities.append((*_file_identity(info), _mount_id(fd, deadline)))
            else:
                identities.append(_executable_identity(info) if name == 'exe' else _file_identity(info))
        if _start_time(proc_fd, pid, deadline) != start or _uids(proc_fd, deadline) != uids:
            raise ValueError('context_unavailable')
        result.identity = (start, uids, *identities)
        _remaining(deadline)
        return result
    except BaseException:
        result.close()
        raise


class _ContextLease:
    """Private held descriptors; only the final booleans may leave the probe."""

    def __init__(self, pidfd, peer_pid, peer_fd, worker_pid, worker_fd, executable):
        self._identity_owner = os.getpid(), threading.get_native_id()
        self._fds = [pidfd, peer_fd, worker_fd]
        self._peer_pid = peer_pid
        self._worker_pid = worker_pid
        self._executable = executable
        self._snapshots = []
        self._trusted_identity = None
        self.context = None

    def capture(self, uid, deadline):
        if not _pidfd_alive(self._fds[0]):
            raise ValueError('context_unavailable')
        self._trusted_identity = _executable_identity(_trusted_executable(self._executable, deadline))
        for fd, pid in ((self._fds[1], self._peer_pid), (self._fds[2], self._worker_pid)):
            self._snapshots.append(_snapshot(fd, pid, deadline))
        peer, worker = (item.identity for item in self._snapshots)
        if peer[1] != (uid,) * 4 or peer[2] != self._trusted_identity:
            raise ValueError('context_unavailable')
        self.context = DaemonContext(peer[3] == worker[3], peer[4] == worker[4], peer[5] == worker[5])
        if not self.revalidate(deadline):
            raise ValueError('context_unavailable')

    def revalidate(self, deadline):
        fresh = []
        try:
            _remaining(deadline)
            if not self._fds or not _pidfd_alive(self._fds[0]):
                return False
            if _executable_identity(_trusted_executable(self._executable, deadline)) != self._trusted_identity:
                return False
            for fd, pid in ((self._fds[1], self._peer_pid), (self._fds[2], self._worker_pid)):
                fresh.append(_snapshot(fd, pid, deadline))
            _remaining(deadline)
            return (_pidfd_alive(self._fds[0])
                    and [item.identity for item in fresh] == [item.identity for item in self._snapshots])
        except _ERRORS:
            return False
        finally:
            for item in fresh:
                item.close()

    def close(self):
        for item in self._snapshots:
            item.close()
        self._snapshots = []
        descriptors, self._fds = self._fds, []
        for fd in reversed(descriptors):
            _close(fd)

    def capture_identities(self, deadline, *, cancelled=None):
        """Optional private UID/GID/maps, bound to these held proc/pidfd handles.

        The existing three public context booleans retain their old contract.
        This supplies process provenance, never host/remap or write authority.
        """
        from .linux_identity_observation import _capture_context_identities
        return _capture_context_identities(self, deadline, cancelled=cancelled)


def capture_daemon_context(connection, expected_uid, daemon_executable, deadline):
    """Capture from this verified connection, or return None without detail.

    Linux 6.5 introduced SO_PEERPIDFD (77 on the supported amd64/arm64 ABIs).
    Its absence affects context evidence only; GET /version remains usable.
    """
    descriptors = []
    lease = None
    transferred = False
    try:
        _remaining(deadline)
        if sys.platform != 'linux' or daemon_executable is None:
            return None
        credentials = connection.getsockopt(socket.SOL_SOCKET, getattr(socket, 'SO_PEERCRED', 17), 12)
        pid, uid, gid = struct.unpack('3i', credentials)
        if pid <= 0 or uid != expected_uid or gid < 0:
            return None
        raw = connection.getsockopt(socket.SOL_SOCKET, getattr(socket, 'SO_PEERPIDFD', 77), 4)
        pidfd = struct.unpack('i', raw)[0]
        if pidfd < 0:
            return None
        descriptors.append(pidfd)
        os.set_inheritable(pidfd, False)
        if not _pidfd_alive(pidfd):
            return None
        worker_pid, worker_path = _worker_process()
        for process_path in (_PROC_ROOT / str(pid), worker_path):
            _remaining(deadline)
            descriptors.append(os.open(process_path,
                                       os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC))
        lease = _ContextLease(pidfd, pid, descriptors[1], worker_pid, descriptors[2], daemon_executable)
        descriptors = []
        lease.capture(uid, deadline)
        transferred = True
        return lease
    except _ERRORS:
        return None
    finally:
        if lease is not None and not transferred:
            lease.close()
        for fd in reversed(descriptors):
            _close(fd)
