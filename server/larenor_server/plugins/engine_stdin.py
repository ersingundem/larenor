"""Bounded private stdin transport for one exact Docker container attach.

The transport verifies API compatibility, Unix socket ancestry and peer identity
before a mandatory synchronous gate. It then upgrades the same connection for
one generated container ID and sends at most 4096 private bytes. There is no
public/IPC entry point, arbitrary path, TTY, websocket, retry or environment
fallback. Callers still own create/start/wait/remove and journal authority.
"""

from dataclasses import dataclass
import math
import re
import socket
import threading
import time

from ..services.transport import (
    ProbeResponse,
    ProbeTransportError,
    _Deadline,
    _remaining,
    _request_bytes,
)
from .docker_probe import DockerEndpoint, _compatibility, _identity, _linux_peer_uid
from .engine_http import EngineHttpError, _EngineReader, _body, _headers
from .worker import DockerWorkerError


_CONTAINER_ID = re.compile(r'[0-9a-f]{64}\Z')
_PLATFORMS = frozenset({'linux/amd64', 'linux/arm64'})
_TOKEN = re.compile(rb"[!#$%&'*+.^_`|~0-9A-Za-z-]+\Z")
_CODES = frozenset({
    'engine_stdin_invalid', 'engine_stdin_invalid_limits',
    'engine_stdin_protocol', 'engine_stdin_response_limit',
    'engine_stdin_unavailable', 'engine_stdin_timeout',
    'engine_stdin_cancelled', 'engine_stdin_api_unsupported',
    'engine_stdin_dispatch_denied',
    'engine_stdin_version_protocol',
    'engine_stdin_attach_protocol',
    'engine_stdin_frames_protocol',
})


class EngineStdinError(Exception):
    """Static diagnostic; input bytes, socket paths and daemon output are hidden."""

    def __init__(self, code='engine_stdin_unavailable'):
        self.code = code if code in _CODES else 'engine_stdin_unavailable'
        super().__init__(self.code)


def _require(value, code='engine_stdin_protocol'):
    if not value:
        raise EngineStdinError(code)


@dataclass(frozen=True)
class EngineStdinLimits:
    total_seconds: float = 10.0
    idle_seconds: float = 2.0
    max_output_bytes: int = 4096
    max_frames: int = 32

    def __post_init__(self):
        _require(type(self.total_seconds) in (int, float)
                 and math.isfinite(self.total_seconds)
                 and 0 < self.total_seconds <= 30
                 and type(self.idle_seconds) in (int, float)
                 and math.isfinite(self.idle_seconds)
                 and 0 < self.idle_seconds <= 2
                 and self.idle_seconds <= self.total_seconds
                 and type(self.max_output_bytes) is int
                 and 1 <= self.max_output_bytes <= 4096
                 and type(self.max_frames) is int
                 and 1 <= self.max_frames <= 64,
                 'engine_stdin_invalid_limits')


def _upgrade_headers(reader):
    first = reader.line(8192)
    _require(re.fullmatch(rb'HTTP/1\.1 101(?: [\x20-\x7e]*)?\r\n', first) is not None)
    total, headers = len(first), []
    while True:
        line = reader.line(min(8192, 32768 - total))
        total += len(line)
        if line == b'\r\n':
            break
        _require(len(headers) < 100 and b':' in line)
        name, value = line[:-2].split(b':', 1)
        _require(_TOKEN.fullmatch(name) is not None
                 and not any(byte < 32 and byte != 9 or byte == 127 for byte in value))
        headers.append((name.decode('ascii').lower(), value.decode('latin1').strip(' \t')))
    values = {}
    for name, value in headers:
        _require(name not in values)
        values[name] = value
    connection = tuple(
        item.strip().lower() for item in values.get('connection', '').split(','))
    _require('upgrade' in connection and values.get('upgrade', '').lower() == 'tcp')
    content_type = values.get('content-type')
    _require(content_type is None
             or content_type.split(';', 1)[0].strip().lower()
             in {
                 'application/vnd.docker.raw-stream',
                 'application/vnd.docker.multiplexed-stream',
             })


def _multiplex(reader, limits):
    stdout, stderr = bytearray(), bytearray()
    total = 0
    for _ in range(limits.max_frames + 1):
        prefix = reader.receive(8)
        if not prefix:
            return bytes(stdout), bytes(stderr)
        if len(prefix) < 8:
            prefix += reader.exact(8 - len(prefix))
        _require(prefix[0] in (1, 2) and prefix[1:4] == b'\x00\x00\x00')
        length = int.from_bytes(prefix[4:], 'big')
        _require(1 <= length <= limits.max_output_bytes - total,
                 'engine_stdin_response_limit')
        payload = reader.exact(length)
        (stdout if prefix[0] == 1 else stderr).extend(payload)
        total += length
    raise EngineStdinError('engine_stdin_response_limit')


def _http_code(error, protocol):
    return {
        'engine_cancelled': 'engine_stdin_cancelled',
        'engine_timeout': 'engine_stdin_timeout',
        'engine_stream_limit': 'engine_stdin_response_limit',
        'engine_protocol': protocol,
    }.get(error.code, 'engine_stdin_unavailable')


def _probe_code(error, protocol):
    return {
        'request_timeout': 'engine_stdin_timeout',
        'response_too_large': 'engine_stdin_response_limit',
    }.get(error.code, protocol)


def _version_response(reader):
    try:
        status, headers = _headers(reader)
        body = b''.join(_body(reader, headers, 65536, 4096))
        return status, headers, body
    except EngineHttpError as error:
        raise EngineStdinError(_http_code(
            error, 'engine_stdin_version_protocol')) from None
    except ProbeTransportError as error:
        raise EngineStdinError(_probe_code(
            error, 'engine_stdin_version_protocol')) from None


def _attach_response(reader):
    try:
        _upgrade_headers(reader)
    except EngineStdinError as error:
        code = ('engine_stdin_attach_protocol'
                if error.code == 'engine_stdin_protocol' else error.code)
        raise EngineStdinError(code) from None
    except EngineHttpError as error:
        raise EngineStdinError(_http_code(
            error, 'engine_stdin_attach_protocol')) from None
    except ProbeTransportError as error:
        raise EngineStdinError(_probe_code(
            error, 'engine_stdin_attach_protocol')) from None


def _stream_response(reader, limits):
    try:
        return _multiplex(reader, limits)
    except EngineStdinError as error:
        code = ('engine_stdin_frames_protocol'
                if error.code == 'engine_stdin_protocol' else error.code)
        raise EngineStdinError(code) from None
    except EngineHttpError as error:
        raise EngineStdinError(_http_code(
            error, 'engine_stdin_frames_protocol')) from None
    except ProbeTransportError as error:
        raise EngineStdinError(_probe_code(
            error, 'engine_stdin_frames_protocol')) from None


def _attach_wire(container_id):
    target = (f'/v1.47/containers/{container_id}/attach?'
              'stream=1&stdin=1&stdout=1&stderr=1')
    return (f'POST {target} HTTP/1.1\r\n'
            'Host: localhost\r\n'
            'Connection: Upgrade\r\n'
            'Upgrade: tcp\r\n'
            'Content-Length: 0\r\n\r\n').encode('ascii')


class UnixEngineStdin:
    """One no-retry, gate-protected private input exchange."""

    def __init__(self, endpoint, *, peer_uid=None):
        _require(type(endpoint) is DockerEndpoint
                 and (peer_uid is None or callable(peer_uid)),
                 'engine_stdin_invalid')
        self._endpoint = endpoint
        self._peer_uid = _linux_peer_uid if peer_uid is None else peer_uid

    def exchange(self, container_id, input_bytes, consume, *, platform, limits,
                 before_dispatch=None, cancelled=None):
        _require(type(container_id) is str
                 and _CONTAINER_ID.fullmatch(container_id) is not None
                 and type(input_bytes) is bytes and 1 <= len(input_bytes) <= 4096
                 and callable(consume) and platform in _PLATFORMS
                 and type(limits) is EngineStdinLimits
                 and callable(before_dispatch), 'engine_stdin_invalid')
        try:
            endpoint = DockerEndpoint(**vars(self._endpoint))
            limits = EngineStdinLimits(**vars(limits))
        except (ValueError, TypeError):
            raise EngineStdinError('engine_stdin_invalid') from None
        cancelled = threading.Event() if cancelled is None else cancelled
        _require(type(cancelled) is threading.Event, 'engine_stdin_invalid')
        _require(not cancelled.is_set(), 'engine_stdin_cancelled')
        deadline = time.monotonic() + limits.total_seconds
        watcher = None
        try:
            before = _identity(endpoint)
            watcher = _Deadline(deadline)
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            watcher.attach(connection)
            connection.settimeout(min(_remaining(deadline), limits.idle_seconds))
            connection.connect(endpoint.path)
            _require(_identity(endpoint) == before, 'engine_stdin_unavailable')
            peer = self._peer_uid(connection)
            _require(type(peer) is int and peer == endpoint.owner_uid,
                     'engine_stdin_unavailable')
            reader = _EngineReader(connection, deadline, limits, cancelled)
            version_wire = _request_bytes(
                'GET', '/version', 'localhost', {'Accept': 'application/json'}, None)
            connection.sendall(version_wire.replace(
                b'Connection: close\r\n', b'Connection: keep-alive\r\n', 1))
            status, headers, version = _version_response(reader)
            _require(_compatibility(ProbeResponse(status, headers, version), platform)
                     == 'passed', 'engine_stdin_api_unsupported')
            _require(not any(name == 'connection' and 'close' in value.lower()
                             for name, value in headers),
                     'engine_stdin_api_unsupported')
            _require(_identity(endpoint) == before, 'engine_stdin_unavailable')
            _require(not cancelled.is_set(), 'engine_stdin_cancelled')
            try:
                permitted = before_dispatch() is True
            except Exception:
                raise EngineStdinError('engine_stdin_dispatch_denied') from None
            _require(permitted, 'engine_stdin_dispatch_denied')
            _require(_identity(endpoint) == before, 'engine_stdin_unavailable')
            _require(not cancelled.is_set(), 'engine_stdin_cancelled')
            connection.sendall(_attach_wire(container_id))
            _attach_response(reader)
            _require(_identity(endpoint) == before, 'engine_stdin_unavailable')
            _require(not cancelled.is_set(), 'engine_stdin_cancelled')
            try:
                permitted = before_dispatch() is True
            except Exception:
                raise EngineStdinError('engine_stdin_dispatch_denied') from None
            _require(permitted, 'engine_stdin_dispatch_denied')
            _require(_identity(endpoint) == before, 'engine_stdin_unavailable')
            _require(not cancelled.is_set(), 'engine_stdin_cancelled')
            connection.sendall(input_bytes)
            connection.shutdown(socket.SHUT_WR)
            stdout, stderr = _stream_response(reader, limits)
            result = consume(stdout, stderr)
            _require(_identity(endpoint) == before, 'engine_stdin_unavailable')
            _require(not cancelled.is_set(), 'engine_stdin_cancelled')
            _require(time.monotonic() < deadline, 'engine_stdin_timeout')
            return result
        except EngineStdinError:
            raise
        except EngineHttpError as error:
            code = {
                'engine_cancelled': 'engine_stdin_cancelled',
                'engine_timeout': 'engine_stdin_timeout',
                'engine_stream_limit': 'engine_stdin_response_limit',
                'engine_protocol': 'engine_stdin_protocol',
            }.get(error.code, 'engine_stdin_unavailable')
            raise EngineStdinError(code) from None
        except (OSError, ValueError, TypeError, RuntimeError, DockerWorkerError,
                ProbeTransportError) as error:
            if cancelled.is_set():
                code = 'engine_stdin_cancelled'
            elif time.monotonic() >= deadline or isinstance(error, TimeoutError):
                code = 'engine_stdin_timeout'
            elif isinstance(error, ProbeTransportError):
                code = 'engine_stdin_protocol'
            else:
                code = 'engine_stdin_unavailable'
            raise EngineStdinError(code) from None
        finally:
            if watcher is not None:
                watcher.finish()
