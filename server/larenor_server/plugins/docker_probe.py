"""Worker-only, read-only Docker API/platform observation over a Unix socket.

``passed`` proves only that this daemon advertises the worker's API 1.47 and
requested platform. It says nothing about images, privileges or installation.
The operator supplies a canonical socket path; environment Docker/proxy settings
are never consulted. No mutating Engine client is constructed or exposed.

Official schema and transport references:
https://docs.docker.com/reference/api/engine/version/v1.47/
https://docs.docker.com/engine/security/protect-access/
https://docs.docker.com/reference/api/engine/#minimum-api-version
"""

from dataclasses import dataclass, field
import json
import math
from pathlib import PurePosixPath
import re
import socket
import stat
import struct
import sys
import time
from typing import Literal
import unicodedata

from ..services.transport import (
    _Deadline, _Reader, _remaining, _request_bytes, _response, ProbeTransportError,
)
from .worker import _safe_path, DockerWorkerError
from .daemon_context import DaemonContext, capture_daemon_context


_API_VERSION = (1, 47)
_MAX_BODY = 65536
_VERSION = re.compile(r'(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\Z')
_PLATFORM_PART = re.compile(r'[a-z0-9_]{1,32}\Z')
_REQUEST = _request_bytes('GET', '/version', 'localhost', {'Accept': 'application/json'}, None)


@dataclass(frozen=True)
class DockerEndpoint:
    """Private operator configuration; validation never observes the host."""

    path: str = field(repr=False)
    owner_uid: int = 0
    daemon_executable: str | None = field(default=None, repr=False)

    def __post_init__(self):
        try:
            valid = (
                type(self.path) is str and self.path.startswith('/')
                and not self.path.startswith('//') and self.path != '/'
                and PurePosixPath(self.path).as_posix() == self.path
                and '..' not in PurePosixPath(self.path).parts and '\\' not in self.path
                and not any(unicodedata.category(char).startswith('C') for char in self.path)
                and len(self.path.encode('utf-8')) <= 107
                and type(self.owner_uid) is int and 0 <= self.owner_uid < 2**31
                and (self.daemon_executable is None or _canonical_executable(self.daemon_executable))
            )
        except (ValueError, UnicodeError):
            valid = False
        if not valid:
            raise ValueError('invalid_docker_endpoint') from None


def _canonical_executable(path):
    return (type(path) is str and path.startswith('/') and not path.startswith('//')
            and path != '/' and PurePosixPath(path).as_posix() == path
            and '..' not in PurePosixPath(path).parts and '\\' not in path
            and not any(unicodedata.category(char).startswith('C') for char in path)
            and len(path.encode('utf-8')) <= 4096)


@dataclass(frozen=True)
class DockerObservation:
    status: Literal['passed', 'failed', 'unknown']
    context: DaemonContext | None
    value: object = field(default=None, repr=False)


def _linux_peer_uid(connection):
    if sys.platform != 'linux' or not hasattr(socket, 'SO_PEERCRED'):
        raise OSError('peer_unavailable')
    credentials = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize('3i'))
    return struct.unpack('3i', credentials)[1]


def _identity(endpoint):
    path = _safe_path(endpoint.path, uid=endpoint.owner_uid, kind=stat.S_ISSOCK)
    # Bind the entire canonical ancestry as well as the socket inode. Socket
    # group access is legitimate, but a group/world-writable ancestor is not
    # (except a root-owned sticky temporary ancestor, as in _safe_path).
    result = []
    for item in (*reversed(path.parents), path):
        info = item.lstat()
        if item != path:
            valid = (stat.S_ISDIR(info.st_mode) and info.st_uid in {0, endpoint.owner_uid}
                     and (info.st_mode & 0o022 == 0
                          or info.st_uid == 0 and info.st_mode & stat.S_ISVTX))
        else:
            valid = (stat.S_ISSOCK(info.st_mode) and info.st_uid == endpoint.owner_uid
                     and info.st_mode & 0o007 == 0)
        if not valid:
            raise ValueError('endpoint_untrusted')
        result.append((info.st_dev, info.st_ino, info.st_uid, info.st_gid, info.st_mode))
    return tuple(result)


def _unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('invalid_version')
        result[key] = value
    return result


def _reject_constant(_value):
    raise ValueError('invalid_version')


def _finite_float(value):
    number = float(value)
    if not math.isfinite(number):
        raise ValueError('invalid_version')
    return number


def _compatibility(response, expected_platform):
    if response.status != 200:
        return 'unknown'
    content_types = [value.lower() for key, value in response.headers if key == 'content-type']
    if len(content_types) != 1 or content_types[0].split(';', 1)[0].strip() != 'application/json':
        return 'unknown'
    value = json.loads(response.body.decode('utf-8'), object_pairs_hook=_unique_pairs,
                       parse_constant=_reject_constant, parse_float=_finite_float)
    if type(value) is not dict:
        return 'unknown'
    versions = []
    for key in ('MinAPIVersion', 'ApiVersion'):
        version = value.get(key)
        if type(version) is not str or not _VERSION.fullmatch(version):
            return 'unknown'
        versions.append(tuple(int(part) for part in version.split('.')))
    if versions[0] > versions[1]:
        return 'unknown'
    for key in ('Os', 'Arch'):
        if type(value.get(key)) is not str or not _PLATFORM_PART.fullmatch(value[key]):
            return 'unknown'
    if not versions[0] <= _API_VERSION <= versions[1]:
        return 'failed'
    return 'passed' if f"{value['Os']}/{value['Arch']}" == expected_platform else 'failed'


class DockerProbe:
    """One bounded GET /version; test seams are trusted in-process dependencies."""

    def __init__(self, endpoint: DockerEndpoint, *, timeout=2.0, socket_factory=None, peer_uid=None):
        if (type(endpoint) is not DockerEndpoint or type(timeout) not in (int, float)
                or not math.isfinite(timeout) or not 0 < timeout <= 2
                or socket_factory is not None and not callable(socket_factory)
                or peer_uid is not None and not callable(peer_uid)):
            raise ValueError('invalid_docker_probe')
        self._endpoint = endpoint
        self._timeout = timeout
        self._socket_factory = socket.socket if socket_factory is None else socket_factory
        self._peer_uid = _linux_peer_uid if peer_uid is None else peer_uid

    def inspect(self, expected_platform: str) -> Literal['passed', 'failed', 'unknown']:
        return self._observe(expected_platform, None, None, False).status

    def observe(self, expected_platform: str, *, during=None, deadline=None) -> DockerObservation:
        """Bracket one trusted local callback without retrying or discarding it.

        This callback is independently budgeted by the caller. An overrun can
        retain its local value, but never publish passed Docker/context facts.
        No executable policy or older kernels still permit API compatibility.
        """
        if (during is not None and not callable(during)
                or deadline is not None and (type(deadline) not in (int, float) or not math.isfinite(deadline))):
            raise ValueError('invalid_observation')
        return self._observe(expected_platform, during, deadline, True)

    def _observe(self, expected_platform, during, deadline, observe_context):
        if type(expected_platform) is not str or expected_platform not in ('linux/amd64', 'linux/arm64'):
            raise ValueError('invalid_platform')
        own_deadline = time.monotonic() + self._timeout
        deadline = own_deadline if deadline is None else min(own_deadline, deadline)
        watchdog = None
        lease = None
        result = 'unknown'
        context = None
        try:
            try:
                _remaining(deadline)
                if self._peer_uid is _linux_peer_uid and (sys.platform != 'linux' or not hasattr(socket, 'SO_PEERCRED')):
                    raise OSError('peer_unavailable')
                before = _identity(self._endpoint)
                watchdog = _Deadline(deadline)
                connection = self._socket_factory(socket.AF_UNIX, socket.SOCK_STREAM)
                watchdog.attach(connection)
                connection.settimeout(_remaining(deadline))
                connection.connect(self._endpoint.path)
                if _identity(self._endpoint) != before:
                    raise ValueError('endpoint_changed')
                peer = self._peer_uid(connection)
                if type(peer) is not int or peer != self._endpoint.owner_uid:
                    raise ValueError('peer_unavailable')
                if observe_context and self._endpoint.daemon_executable is not None:
                    lease = capture_daemon_context(connection, self._endpoint.owner_uid,
                                                   self._endpoint.daemon_executable, deadline)
                connection.settimeout(_remaining(deadline))
                connection.sendall(_REQUEST)
                response = _response(_Reader(connection, deadline), _MAX_BODY)
                if _identity(self._endpoint) != before:
                    raise ValueError('endpoint_changed')
                result = _compatibility(response, expected_platform)
                _remaining(deadline)
            except (OSError, ValueError, TypeError, RuntimeError, struct.error,
                    ProbeTransportError, DockerWorkerError):
                result = 'unknown'
            # Callback errors intentionally propagate after cleanup. Catching
            # them as transport errors could cause the caller to retry work.
            value = during() if during is not None else None
            try:
                _remaining(deadline)
                if result != 'unknown':
                    if _identity(self._endpoint) != before:
                        raise ValueError('endpoint_changed')
                    if lease is not None and lease.revalidate(deadline):
                        context = lease.context
                    _remaining(deadline)
            except (OSError, ValueError, TypeError, RuntimeError, struct.error,
                    ProbeTransportError, DockerWorkerError):
                result, context = 'unknown', None
            return DockerObservation(result, context, value)
        finally:
            if lease is not None:
                lease.close()
            if watchdog is not None:
                watchdog.finish()
