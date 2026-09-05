"""Bounded, read-only Linux 6.1 mount evidence for an already held directory.

No daemon/supervisor, initial user namespace or UID mapping is authenticated
here. These private in-process facts are not a lease or permission to write.
The original directory FD remains caller-owned. Observations do not reserve
resources or stop a privileged actor changing mounts after the final check.

Linux 6.1 prints ``idmapped`` in mountinfo's per-mount options:
https://github.com/torvalds/linux/blob/v6.1/fs/proc_namespace.c#L64-L85
https://man7.org/linux/man-pages/man5/proc_pid_mountinfo.5.html
https://man7.org/linux/man-pages/man5/proc_pid_fdinfo.5.html

FDs pin mount objects while fdinfo IDs are compared. They are the older mount
IDs, not STATX_MNT_ID_UNIQUE, and must not be supplied to statmount. Proc data
is bounded; deadline checks do not promise to interrupt a stalled filesystem
syscall. Kernel/provider errors never include source data in public errors.
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


MAX_MOUNTINFO_BYTES = 262144
MAX_MOUNT_ROWS = 4096
MAX_LINE_BYTES = 8192
MAX_FDINFO_BYTES = 16384
_PROC_ROOT = Path('/proc')
_ERRORS = (OSError, ValueError, TypeError, RuntimeError, OverflowError)
_DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


class MountObservationError(Exception):
    """Only a fixed, source-free error may escape the observation boundary."""


def _require(condition):
    if not condition:
        raise MountObservationError('mount_observation_unavailable') from None


def _deadline(deadline):
    _require(type(deadline) in (int, float) and math.isfinite(deadline)
             and time.monotonic() < deadline)


def _number(value, maximum=2**31 - 1, *, zero=False):
    _require(bool(re.fullmatch(rb'0|[1-9][0-9]{0,19}', value)))
    number = int(value)
    _require((0 if zero else 1) <= number <= maximum)
    return number


def _lines(data, maximum, row_limit):
    _require(type(data) is bytes and 0 < len(data) <= maximum and data.endswith(b'\n'))
    rows = data[:-1].split(b'\n')
    _require(len(rows) <= row_limit)
    _require(all(0 < len(line) <= MAX_LINE_BYTES and b'\x00' not in line and b'\r' not in line for line in rows))
    return rows


def _unescape(value, *, source=False):
    result = bytearray()
    index = 0
    escapes = {b'040': 32, b'011': 9, b'012': 10, b'134': 92}
    if source:
        escapes[b'043'] = 35
    while index < len(value):
        byte = value[index]
        if byte == 92:
            code = value[index + 1:index + 4]
            _require(code in escapes)
            result.append(escapes[code])
            index += 4
        else:
            _require(byte >= 33 and byte != 127)
            result.append(byte)
            index += 1
    return bytes(result)


def _path(value):
    decoded = _unescape(value)
    _require(0 < len(decoded) <= 4096 and decoded.startswith(b'/'))
    _require(decoded == b'/' or all(part not in (b'', b'.', b'..') for part in decoded[1:].split(b'/')))
    # Kernel paths are filesystem bytes; preserve non-UTF8 names losslessly.
    return os.fsdecode(decoded)


def _options(value):
    options = value.split(b',')
    _require(0 < len(options) <= 128 and len(options) == len(set(options)))
    _require(all(option and len(option) <= 4096
                 and all(33 <= char <= 126 for char in option) for option in options))
    _require((b'rw' in options) != (b'ro' in options))
    return tuple(option.decode('ascii') for option in options)


def _optional(fields):
    names = set()
    for field in fields:
        parts = field.split(b':')
        name = parts[0]
        _require(name not in names)
        names.add(name)
        if name == b'unbindable':
            _require(len(parts) == 1)
        else:
            _require(name in (b'shared', b'master', b'propagate_from') and len(parts) == 2)
            _number(parts[1])
    _require(b'unbindable' not in names or len(names) == 1)
    _require(b'propagate_from' not in names or b'master' in names)
    return tuple(field.decode('ascii') for field in fields)


@dataclass(frozen=True, repr=False)
class MountRecord:
    mount_id: int
    parent_id: int
    device_major: int
    device_minor: int
    root: str
    mount_point: str
    mount_options: tuple[str, ...]
    optional_fields: tuple[str, ...]
    filesystem: str
    super_options: tuple[str, ...]

    @property
    def read_only(self):
        return 'ro' in self.mount_options or 'ro' in self.super_options

    @property
    def idmapped(self):
        return 'idmapped' in self.mount_options


def parse_mountinfo(data):
    """Parse complete bounded bytes; readonly/idmapped remain explicit facts."""
    records = []
    seen = set()
    for line in _lines(data, MAX_MOUNTINFO_BYTES, MAX_MOUNT_ROWS):
        fields = line.split(b' ')
        _require(all(fields) and fields.count(b'-') == 1)
        separator = fields.index(b'-')
        _require(separator >= 6 and len(fields) == separator + 4)
        mount_id, parent_id = _number(fields[0]), _number(fields[1])
        _require(mount_id not in seen)
        seen.add(mount_id)
        device = fields[2].split(b':')
        _require(len(device) == 2)
        major, minor = (_number(part, 2**32 - 1, zero=True) for part in device)
        filesystem = fields[separator + 1]
        _require(bool(re.fullmatch(rb'[A-Za-z0-9_.+-]{1,128}', filesystem)))
        _require(bool(_unescape(fields[separator + 2], source=True)))
        records.append(MountRecord(mount_id, parent_id, major, minor,
            _path(fields[3]), _path(fields[4]), _options(fields[5]),
            _optional(fields[6:separator]), filesystem.decode('ascii'),
            _options(fields[separator + 3])))
    return tuple(records)


def parse_fdinfo_mount_id(data):
    """Extract one strictly positive old mount ID without assuming other facts."""
    fields = {}
    for line in _lines(data, MAX_FDINFO_BYTES, 256):
        parts = line.split(b':', 1)
        _require(len(parts) == 2 and bool(re.fullmatch(rb'[A-Za-z_][A-Za-z0-9_]*', parts[0])))
        name, value = parts[0], parts[1].strip(b' \t')
        _require(name not in fields and bool(value) and all(32 <= byte <= 126 for byte in value))
        fields[name] = value
    _require(b'mnt_id' in fields)
    return _number(fields[b'mnt_id'])


def _close(descriptor):
    try:
        os.close(descriptor)
    except OSError:
        # Do not retry close: the numeric descriptor may already be reusable.
        pass


def _read(directory_fd, name, max_bytes, deadline):
    descriptor = -1
    try:
        _deadline(deadline)
        descriptor = os.open(name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
                             dir_fd=directory_fd)
        _require(stat.S_ISREG(os.fstat(descriptor).st_mode))
        result = bytearray()
        while len(result) <= max_bytes:
            _deadline(deadline)
            chunk = os.read(descriptor, min(4096, max_bytes + 1 - len(result)))
            _deadline(deadline)
            if not chunk:
                return bytes(result)
            result.extend(chunk)
        _require(False)
    except _ERRORS:
        raise MountObservationError('mount_observation_unavailable') from None
    finally:
        if descriptor >= 0:
            _close(descriptor)


def _identity(fd):
    value = os.fstat(fd)
    _require(stat.S_ISDIR(value.st_mode))
    return value.st_dev, value.st_ino, value.st_uid, value.st_gid, stat.S_IMODE(value.st_mode)


def _mount_id(fd, fdinfo, deadline):
    return parse_fdinfo_mount_id(_read(fdinfo, str(fd), MAX_FDINFO_BYTES, deadline))


def _context(proc, fdinfo, deadline, handles):
    _deadline(deadline)
    # These fixed procfs magic links intentionally follow the process's current
    # namespace/root. No operator or network path is accepted here.
    namespace = os.open('ns/mnt', os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=proc)
    handles.append(namespace)
    root = os.open('root', getattr(os, 'O_PATH', os.O_RDONLY) | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=proc)
    handles.append(root)
    info = os.fstat(namespace)
    return (info.st_dev, info.st_ino), (*_identity(root), _mount_id(root, fdinfo, deadline))


@dataclass(frozen=True, repr=False)
class MountObservation:
    mount: MountRecord
    directory_identity: tuple[int, ...]
    namespace_identity: tuple[int, int]
    process_root_identity: tuple[int, ...]

    @property
    def mount_id(self):
        return self.mount.mount_id

    @property
    def idmapped(self):
        return self.mount.idmapped

    @property
    def read_only(self):
        return self.mount.read_only


def observe_fd_mount(fd, *, deadline):
    """Observe one borrowed directory FD, with before/after context checks.

    Successful return is an observation only, including on readonly/idmapped
    mounts. The future issuer must reject those facts for its own write policy.
    Missing/inaccessible/changed evidence raises a fixed error. No FDs escape.
    """
    handles = []
    try:
        _deadline(deadline)
        deadline = min(deadline, time.monotonic() + 2.0)
        _require(sys.platform == 'linux' and type(fd) is int and fd >= 0)
        held = os.dup(fd)
        handles.append(held)
        os.set_inheritable(held, False)
        identity = _identity(held)
        owner = os.getpid(), threading.get_native_id()
        process_path = _PROC_ROOT / str(owner[0]) / 'task' / str(owner[1])
        proc = os.open(process_path, _DIRECTORY_FLAGS)
        handles.append(proc)
        fdinfo = os.open('fdinfo', _DIRECTORY_FLAGS, dir_fd=proc)
        handles.append(fdinfo)
        context = _context(proc, fdinfo, deadline, handles)
        snapshots = []
        for _ in range(2):
            _deadline(deadline)
            mount_id = _mount_id(held, fdinfo, deadline)
            records = parse_mountinfo(_read(proc, 'mountinfo', MAX_MOUNTINFO_BYTES, deadline))
            matching = [record for record in records if record.mount_id == mount_id]
            _require(len(matching) == 1)
            record = matching[0]
            _require((record.device_major, record.device_minor) == (os.major(identity[0]), os.minor(identity[0])))
            _require(_mount_id(held, fdinfo, deadline) == mount_id)
            snapshots.append(record)
        fresh_proc = os.open(process_path, _DIRECTORY_FLAGS)
        handles.append(fresh_proc)
        fresh_fdinfo = os.open('fdinfo', _DIRECTORY_FLAGS, dir_fd=fresh_proc)
        handles.append(fresh_fdinfo)
        _require(_identity(proc) == _identity(fresh_proc) and _identity(fdinfo) == _identity(fresh_fdinfo))
        _require(_context(fresh_proc, fresh_fdinfo, deadline, handles) == context)
        _require(snapshots[0] == snapshots[1] and _identity(held) == identity)
        _require((os.getpid(), threading.get_native_id()) == owner)
        _deadline(deadline)
        return MountObservation(snapshots[0], identity, *context)
    except _ERRORS:
        raise MountObservationError('mount_observation_unavailable') from None
    finally:
        for handle in reversed(handles):
            _close(handle)
