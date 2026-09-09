"""Held, bounded daemon argv and root-relative configuration evidence.

The caller supplies proc/root descriptors already tied to a socket-derived
pidfd. Paths come only from the trusted daemon's cmdline, are walked beneath its
held process root, and never leave this module through errors or repr output.
"""

import math
import os
import stat
import threading
import time

from .daemon_security import _canonical_path, _config_path


_MAX_RECORD = 65536
_ROOT_UID = 0
_DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
_ERRORS = (OSError, ValueError, TypeError, AttributeError, RuntimeError,
           OverflowError, UnicodeError)


class DaemonStartupError(Exception):
    def __init__(self):
        super().__init__('daemon_startup_unavailable')


def _guard(deadline):
    if (type(deadline) not in (int, float) or not math.isfinite(deadline)
            or time.monotonic() >= deadline):
        raise DaemonStartupError()


def _close(fd):
    try:
        os.close(fd)
    except OSError:
        pass


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_uid, info.st_gid, info.st_mode,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _trusted_directory(fd):
    info = os.fstat(fd)
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != _ROOT_UID
            or info.st_mode & 0o022):
        raise DaemonStartupError()
    return _identity(info)


def _read_fd(fd, deadline):
    value = bytearray()
    while len(value) <= _MAX_RECORD:
        _guard(deadline)
        part = os.read(fd, min(4096, _MAX_RECORD + 1 - len(value)))
        if not part:
            return bytes(value)
        value.extend(part)
    raise DaemonStartupError()


def _read_record(directory, name, deadline):
    _guard(deadline)
    fd = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
                 dir_fd=directory)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise DaemonStartupError()
        return _read_fd(fd, deadline)
    finally:
        _close(fd)


def _argv(raw, daemon_executable):
    if type(raw) is not bytes or not raw or len(raw) > _MAX_RECORD or not raw.endswith(b'\0'):
        raise DaemonStartupError()
    parts = raw[:-1].split(b'\0')
    if not 1 <= len(parts) <= 256 or any(not part for part in parts):
        raise DaemonStartupError()
    try:
        values = tuple(part.decode('utf-8') for part in parts)
        _config_path(values, daemon_executable)
        return values
    except Exception:
        raise DaemonStartupError() from None


def _config(root, path, deadline, *, allow_absent):
    directory = -1
    result = -1
    try:
        _guard(deadline)
        directory = os.dup(root)
        os.set_inheritable(directory, False)
        _trusted_directory(directory)
        parts = tuple(part for part in path.split('/') if part)
        if not parts or not _canonical_path(path):
            raise DaemonStartupError()
        for part in parts[:-1]:
            try:
                child = os.open(part, _DIRECTORY, dir_fd=directory)
            except FileNotFoundError:
                if allow_absent:
                    return None, -1, None
                raise
            _close(directory)
            directory = child
            _trusted_directory(directory)
            _guard(deadline)
        try:
            result = os.open(parts[-1], os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC,
                             dir_fd=directory)
        except FileNotFoundError:
            if allow_absent:
                return None, -1, None
            raise
        info = os.fstat(result)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != _ROOT_UID
                or info.st_mode & 0o022 or info.st_size > _MAX_RECORD):
            raise DaemonStartupError()
        identity = _identity(info)
        data = _read_fd(result, deadline)
        if _identity(os.fstat(result)) != identity:
            raise DaemonStartupError()
        _guard(deadline)
        return data, result, identity
    except BaseException:
        _close(result)
        raise
    finally:
        _close(directory)


def _take(proc, root, daemon_executable, deadline):
    config_fd = -1
    try:
        _guard(deadline)
        proc_identity = _trusted_directory(proc)
        root_identity = _trusted_directory(root)
        raw = _read_record(proc, 'cmdline', deadline)
        argv = _argv(raw, daemon_executable)
        path = _config_path(argv, daemon_executable)
        explicit = any(value == '--config-file' or value.startswith('--config-file=')
                       for value in argv[1:])
        config, config_fd, config_identity = _config(
            root, path, deadline, allow_absent=not explicit and path == '/etc/docker/daemon.json',
        )
        if (_trusted_directory(proc) != proc_identity or _trusted_directory(root) != root_identity
                or _read_record(proc, 'cmdline', deadline) != raw):
            raise DaemonStartupError()
        _guard(deadline)
        expected = (proc_identity, root_identity, raw, argv, path, config, config_identity)
        result, config_fd = config_fd, -1
        return expected, result
    except BaseException:
        _close(config_fd)
        raise


class HeldDaemonStartup:
    def __init__(self, proc, root, daemon_executable, expected, handles):
        self._proc = proc
        self._root = root
        self._daemon_executable = daemon_executable
        self._expected = expected
        self._handles = handles
        self._owner = os.getpid(), threading.get_native_id()
        self._mutex = threading.Lock()

    def __repr__(self):
        return 'HeldDaemonStartup(<private>)'

    @property
    def argv(self):
        return tuple(self._expected[3])

    @property
    def config_path(self):
        return self._expected[4]

    @property
    def config(self):
        value = self._expected[5]
        return None if value is None else bytes(value)

    def _dispose(self):
        handles, self._handles = self._handles, []
        self._proc = self._root = -1
        for fd in reversed(handles):
            _close(fd)

    def check(self, deadline):
        if not self._mutex.acquire(blocking=False):
            raise DaemonStartupError() from None
        fresh_fd = -1
        try:
            _guard(deadline)
            if (not self._handles or self._proc < 0 or self._root < 0
                    or self._owner != (os.getpid(), threading.get_native_id())):
                raise DaemonStartupError()
            fresh, fresh_fd = _take(self._proc, self._root, self._daemon_executable, deadline)
            if fresh != self._expected:
                raise DaemonStartupError()
            config_identity = self._expected[6]
            if config_identity is not None:
                held_config = self._handles[-1]
                if _identity(os.fstat(held_config)) != config_identity:
                    raise DaemonStartupError()
            _guard(deadline)
        except BaseException as error:
            self._dispose()
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            raise DaemonStartupError() from None
        finally:
            _close(fresh_fd)
            self._mutex.release()

    def close(self):
        if not self._mutex.acquire(blocking=False):
            raise DaemonStartupError() from None
        try:
            self._dispose()
        finally:
            self._mutex.release()


def capture_daemon_startup(proc_fd, root_fd, *, pid, daemon_executable, deadline):
    """Capture private startup evidence from retained peer proc/root handles."""
    proc = root = config_fd = -1
    held = None
    try:
        _guard(deadline)
        if (type(proc_fd) is not int or proc_fd < 0 or type(root_fd) is not int or root_fd < 0
                or type(pid) is not int or not 0 < pid < 2**31
                or not _canonical_path(daemon_executable)):
            raise DaemonStartupError()
        proc = os.dup(proc_fd)
        root = os.dup(root_fd)
        os.set_inheritable(proc, False)
        os.set_inheritable(root, False)
        expected, config_fd = _take(proc, root, daemon_executable, deadline)
        handles = [proc, root]
        if config_fd >= 0:
            os.set_inheritable(config_fd, False)
            handles.append(config_fd)
        held = HeldDaemonStartup(proc, root, daemon_executable, expected, handles)
        proc = root = config_fd = -1
        held.check(deadline)
        return held
    except BaseException as error:
        if held is not None:
            held.close()
        for fd in (config_fd, root, proc):
            _close(fd)
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        raise DaemonStartupError() from None
