"""Private rootful/remap-disabled Docker authority attestation.

The active socket peer, process identity and startup evidence are supplied by
the retained native supervisor.  This module adds two bounded read-only Engine
requests and rejects rootless or user-namespace remapping before any effect.
No command, config content, process ID or Engine response leaves this module.

References:
https://docs.docker.com/reference/cli/dockerd/
https://docs.docker.com/engine/security/userns-remap/
https://github.com/moby/moby/blob/v27.5.1/api/swagger.yaml
"""

import json
import math
import os
from pathlib import PurePosixPath
import re
import threading
import time
import unicodedata

from ..services.transport import ProbeResponse, ProbeTransportError, _Reader, _request_bytes
from .docker_probe import _compatibility
from .engine_http import EngineHttpError, _body, _headers


_MAX_BODY = 65536
_MAX_OPTIONS = 64
_MAX_OPTION = 256
_INITIAL_MAP = ((0, 0, 4294967295),)
_PLATFORMS = frozenset({'linux/amd64', 'linux/arm64'})
_NAME = re.compile(r'name=([a-z0-9_-]{1,64})(?:,.*)?\Z')
_ERRORS = (OSError, ValueError, TypeError, AttributeError, RuntimeError,
           OverflowError, UnicodeError, json.JSONDecodeError, ProbeTransportError,
           EngineHttpError)


class DaemonSecurityError(Exception):
    """One static result; startup, config and Engine details remain private."""

    def __init__(self):
        super().__init__('daemon_security_unavailable')


def _guard(deadline):
    if (type(deadline) not in (int, float) or not math.isfinite(deadline)
            or time.monotonic() >= deadline):
        raise DaemonSecurityError()


def _pairs(value):
    try:
        rows = tuple(
            (item.inside_first, item.outside_first, item.length)
            if all(hasattr(item, name) for name in ('inside_first', 'outside_first', 'length'))
            else tuple(item)
            for item in value
        )
        if any(len(row) != 3 or any(type(part) is not int for part in row) for row in rows):
            raise ValueError()
        return rows
    except (TypeError, ValueError, AttributeError):
        raise DaemonSecurityError() from None


def _initial_root(peer, worker):
    try:
        namespaces = (
            peer.target_user_namespace,
            peer.opener_user_namespace,
            worker.target_user_namespace,
            worker.opener_user_namespace,
        )
        return (all(value == namespaces[0] for value in namespaces[1:])
                and peer.uids == peer.gids == worker.uids == worker.gids == (0, 0, 0, 0)
                and _pairs(peer.uid_map) == _INITIAL_MAP
                and _pairs(peer.gid_map) == _INITIAL_MAP
                and _pairs(worker.uid_map) == _INITIAL_MAP
                and _pairs(worker.gid_map) == _INITIAL_MAP)
    except (TypeError, AttributeError, DaemonSecurityError):
        return False


def _canonical_path(value):
    return (type(value) is str and value.startswith('/') and not value.startswith('//')
            and value != '/' and PurePosixPath(value).as_posix() == value
            and '..' not in PurePosixPath(value).parts and '\\' not in value
            and len(value.encode('utf-8')) <= 4096
            and not any(unicodedata.category(char).startswith('C') for char in value))


def _unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError()
        result[key] = value
    return result


def _config_path(argv, daemon_executable):
    if (type(argv) is not tuple or not 1 <= len(argv) <= 256
            or any(type(value) is not str or not value or len(value.encode('utf-8')) > 4096
                   or '\x00' in value for value in argv)
            or argv[0] != daemon_executable):
        raise DaemonSecurityError()
    paths = []
    index = 1
    while index < len(argv):
        value = argv[index]
        if value == '--userns-remap' or value.startswith('--userns-remap='):
            raise DaemonSecurityError()
        if value == '--config-file':
            index += 1
            if index >= len(argv):
                raise DaemonSecurityError()
            paths.append(argv[index])
        elif value.startswith('--config-file='):
            paths.append(value.split('=', 1)[1])
        index += 1
    if len(paths) > 1:
        raise DaemonSecurityError()
    path = paths[0] if paths else '/etc/docker/daemon.json'
    if not _canonical_path(path):
        raise DaemonSecurityError()
    return path


def _startup_allows(startup, daemon_executable):
    path = _config_path(startup.argv, daemon_executable)
    if startup.config_path != path:
        raise DaemonSecurityError()
    raw = startup.config
    if raw is None:
        if path != '/etc/docker/daemon.json':
            raise DaemonSecurityError()
        return
    if type(raw) is not bytes or not 0 < len(raw) <= _MAX_BODY:
        raise DaemonSecurityError()
    value = json.loads(raw.decode('utf-8'), object_pairs_hook=_unique_pairs,
                       parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()))
    if type(value) is not dict or 'userns-remap' in value:
        raise DaemonSecurityError()


def _read_response(connection, reader, request, deadline):
    _guard(deadline)
    connection.settimeout(max(0.001, deadline - time.monotonic()))
    wire = _request_bytes('GET', request, 'localhost', {'Accept': 'application/json'}, None)
    connection.sendall(wire.replace(b'Connection: close\r\n',
                                    b'Connection: keep-alive\r\n', 1))
    status, headers = _headers(reader)
    body = b''.join(_body(reader, headers, _MAX_BODY, 4096))
    if any(key == 'connection' and 'close' in value.lower() for key, value in headers):
        raise DaemonSecurityError()
    _guard(deadline)
    return ProbeResponse(status, headers, body)


def _runtime_allows(connection, platform, deadline):
    reader = _Reader(connection, deadline)
    version = _read_response(connection, reader, '/version', deadline)
    if _compatibility(version, platform) != 'passed':
        raise DaemonSecurityError()
    info = _read_response(connection, reader, '/v1.47/info', deadline)
    if info.status != 200:
        raise DaemonSecurityError()
    value = json.loads(info.body.decode('utf-8'), object_pairs_hook=_unique_pairs,
                       parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()))
    options = value.get('SecurityOptions') if type(value) is dict else None
    if (type(options) is not list or not 1 <= len(options) <= _MAX_OPTIONS
            or any(type(option) is not str or not 1 <= len(option) <= _MAX_OPTION
                   or not option.isascii() or any(ord(char) < 32 or ord(char) == 127 for char in option)
                   for option in options)
            or len(set(options)) != len(options)):
        raise DaemonSecurityError()
    names = []
    for option in options:
        match = _NAME.fullmatch(option)
        if match is None:
            raise DaemonSecurityError()
        names.append(match.group(1))
    if any(name in {'rootless', 'userns'} for name in names):
        raise DaemonSecurityError()


class HeldDaemonSecurity:
    """Retain startup/config evidence on the supervisor's native thread."""

    def __init__(self, startup):
        self._startup = startup
        self._owner = os.getpid(), threading.get_native_id()

    def __repr__(self):
        return 'HeldDaemonSecurity(<private>)'

    def _dispose(self):
        startup, self._startup = self._startup, None
        if startup is not None:
            try:
                startup.close()
            except Exception:
                pass

    def check(self, deadline):
        try:
            _guard(deadline)
            if (self._startup is None
                    or self._owner != (os.getpid(), threading.get_native_id())):
                raise DaemonSecurityError()
            self._startup.check(deadline)
            _guard(deadline)
        except BaseException as error:
            self._dispose()
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            raise DaemonSecurityError() from None

    def close(self):
        self._dispose()


def attest_daemon_security(connection, startup, peer, worker, *, daemon_executable,
                           platform, deadline):
    """Return held positive authority or one static failure before mutation."""
    held = None
    try:
        _guard(deadline)
        if (not callable(getattr(connection, 'sendall', None))
                or not callable(getattr(connection, 'recv', None))
                or not callable(getattr(startup, 'check', None))
                or not callable(getattr(startup, 'close', None))
                or not _canonical_path(daemon_executable) or platform not in _PLATFORMS
                or not _initial_root(peer, worker)):
            raise DaemonSecurityError()
        startup.check(deadline)
        _startup_allows(startup, daemon_executable)
        _runtime_allows(connection, platform, deadline)
        startup.check(deadline)
        held = HeldDaemonSecurity(startup)
        held.check(deadline)
        return held
    except BaseException as error:
        if held is not None:
            held.close()
        else:
            try:
                startup.close()
            except Exception:
                pass
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        raise DaemonSecurityError() from None
