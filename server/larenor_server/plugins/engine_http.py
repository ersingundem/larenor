"""Private fixed-operation Unix HTTP transport for trusted worker adapters.

Each exchange authenticates one Unix connection and checks Engine API 1.47 on
that same stream before one operation. This proves no daemon namespace, actor,
journal or installation authority. There is no raw API/IPC entry point, proxy,
TCP fallback, retry, redirect, auth option, or general Docker client here.

Only the existing pinned-image inspect/pull wire shapes are accepted. Catalog
rederivation and response meaning belong to the adapter. The synchronous trusted
consumer must validate its response; its bounded iterator is invalidated before
exchange returns. No configuration or progress content is retained here.
"""

from dataclasses import dataclass, field
import math
import re
import socket
import threading
import time
from urllib.parse import parse_qsl, quote, unquote, urlencode

from ..services.transport import (
    ProbeResponse, ProbeTransportError, _Deadline, _Reader, _remaining, _request_bytes,
)
from .docker_probe import DockerEndpoint, _compatibility, _identity, _linux_peer_uid
from .worker import DockerWorkerError


_CODES = frozenset({'invalid_engine_request', 'invalid_engine_limits', 'engine_protocol',
                    'engine_stream_limit', 'engine_unavailable', 'engine_timeout',
                    'engine_cancelled', 'engine_api_unsupported'})
_TOKEN = re.compile(rb"[!#$%&'*+.^_`|~0-9A-Za-z-]+\Z")
_REFERENCE = re.compile(r'ghcr\.io/[a-z0-9-]+/[a-z0-9-]+@sha256:[0-9a-f]{64}\Z')
_HEADERS = (('Accept', 'application/json'),)
_PLATFORMS = ('linux/amd64', 'linux/arm64')


class EngineHttpError(Exception):
    def __init__(self, code='engine_unavailable'):
        self.code = code if code in _CODES else 'engine_unavailable'
        super().__init__(self.code)


def _require(value, code='engine_protocol'):
    if not value:
        raise EngineHttpError(code)


@dataclass(frozen=True)
class EngineHttpLimits:
    """Trusted per-operation transport bounds, never Client options or quotas."""

    total_seconds: float
    idle_seconds: float
    max_total_bytes: int
    max_chunks: int

    def __post_init__(self):
        for name, maximum in (('total_seconds', 3600), ('idle_seconds', 120)):
            value = getattr(self, name)
            _require(type(value) in (int, float) and math.isfinite(value) and 0 < value <= maximum,
                     'invalid_engine_limits')
        for name, maximum in (('max_total_bytes', 64 * 1024 * 1024), ('max_chunks', 1000000)):
            value = getattr(self, name)
            _require(type(value) is int and 1 <= value <= maximum, 'invalid_engine_limits')


def _reference(value):
    return type(value) is str and len(value) <= 240 and _REFERENCE.fullmatch(value) is not None


@dataclass(frozen=True, repr=False)
class EngineHttpRequest:
    """Closed wire shapes only; possession is not catalog/effect authorization."""

    method: str
    target: str = field(repr=False)
    headers: tuple[tuple[str, str], ...] = field(default=_HEADERS, repr=False)
    body: bytes | None = field(default=None, repr=False)

    def __post_init__(self):
        _require(type(self.method) is str and self.method in ('GET', 'POST')
                 and type(self.target) is str and len(self.target) <= 512
                 and type(self.headers) is tuple and self.headers == _HEADERS
                 and all(type(pair) is tuple and all(type(item) is str for item in pair)
                         for pair in self.headers)
                 and self.body is None, 'invalid_engine_request')
        if self.method == 'GET':
            prefix, suffix = '/v1.47/images/', '/json'
            encoded = self.target[len(prefix):-len(suffix)]
            reference = unquote(encoded)
            valid = (self.target.startswith(prefix) and self.target.endswith(suffix)
                     and _reference(reference) and quote(reference, safe='') == encoded)
        else:
            prefix = '/v1.47/images/create?'
            pairs = parse_qsl(self.target[len(prefix):], keep_blank_values=True)
            valid = (self.target.startswith(prefix) and len(pairs) == 2
                     and pairs[0][0] == 'fromImage' and _reference(pairs[0][1])
                     and pairs[1][0] == 'platform' and pairs[1][1] in _PLATFORMS
                     and prefix + urlencode(pairs) == self.target)
        _require(valid, 'invalid_engine_request')

    def __repr__(self):
        return 'EngineHttpRequest()'


class _EngineReader(_Reader):
    def __init__(self, connection, deadline, limits, cancelled):
        super().__init__(connection, deadline)
        self.limits, self.cancelled = limits, cancelled

    def receive(self, count):
        idle_end = time.monotonic() + self.limits.idle_seconds
        while True:
            _require(not self.cancelled.is_set(), 'engine_cancelled')
            left = min(self.deadline, idle_end) - time.monotonic()
            _require(left > 0, 'engine_timeout')
            self.connection.settimeout(min(left, 0.25))
            try:
                data = self.connection.recv(count)
            except socket.timeout:
                continue
            _require(not self.cancelled.is_set(), 'engine_cancelled')
            _require(time.monotonic() < self.deadline, 'engine_timeout')
            return data


def _headers(reader):
    first = reader.line(8192)
    match = re.fullmatch(rb'HTTP/1\.1 ([2-5][0-9]{2})(?: [\x20-\x7e]*)?\r\n', first)
    _require(match is not None)
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
    return int(match[1]), tuple(headers)


def _body(reader, headers, max_bytes, max_chunks, *, allow_eof=False):
    framing = {}
    for key, value in headers:
        if key in {'content-length', 'transfer-encoding', 'content-encoding', 'content-type'}:
            _require(key not in framing)
            framing[key] = value.lower()
    _require(framing.get('content-encoding', 'identity') == 'identity')
    _require(framing.get('content-type', '').split(';')[0].strip() == 'application/json')
    length, transfer = framing.get('content-length'), framing.get('transfer-encoding')
    _require(transfer in (None, 'chunked') and not (length is not None and transfer is not None))
    total = 0
    if length is not None:
        _require(re.fullmatch(r'[0-9]{1,20}', length) is not None)
        remaining = int(length)
        _require(remaining <= max_bytes, 'engine_stream_limit')
        while remaining:
            piece = reader.exact(min(16384, remaining))
            remaining -= len(piece)
            yield piece
    elif transfer is not None:
        chunks = 0
        while True:
            line = reader.line(128)
            _require(re.fullmatch(rb'[0-9A-Fa-f]{1,16}\r\n', line) is not None)
            size = int(line[:-2], 16)
            if size == 0:
                _require(reader.line(8192) == b'\r\n')
                break
            chunks += 1
            _require(chunks <= max_chunks and size <= max_bytes - total, 'engine_stream_limit')
            total += size
            while size:
                piece = reader.exact(min(16384, size))
                size -= len(piece)
                yield piece
            _require(reader.exact(2) == b'\r\n')
    else:
        _require(allow_eof)
        while True:
            piece = reader.receive(min(16384, max_bytes - total + 1))
            if not piece:
                break
            total += len(piece)
            _require(total <= max_bytes, 'engine_stream_limit')
            yield piece


class _ScopedChunks:
    """No suspended body reader survives the synchronous consumer scope."""

    def __init__(self, iterator):
        self._iterator = iterator
        self._active = True

    def __iter__(self):
        return self

    def __next__(self):
        _require(self._active)
        return next(self._iterator)

    def close(self):
        self._active = False
        self._iterator.close()


class VerifiedEngineHttp:
    """Private adapter dependency: one version check and one fixed operation."""

    def __init__(self, endpoint, *, peer_uid=None):
        _require(type(endpoint) is DockerEndpoint and (peer_uid is None or callable(peer_uid)),
                 'invalid_engine_request')
        self._endpoint = endpoint
        self._peer_uid = _linux_peer_uid if peer_uid is None else peer_uid

    def exchange(self, request, consume, *, platform, limits, cancelled=None):
        _require(type(request) is EngineHttpRequest and callable(consume)
                 and type(platform) is str and platform in _PLATFORMS, 'invalid_engine_request')
        _require(type(limits) is EngineHttpLimits, 'invalid_engine_limits')
        # Revalidate even frozen records against accidental in-process mutation.
        try:
            request = EngineHttpRequest(**vars(request))
            endpoint = DockerEndpoint(**vars(self._endpoint))
        except (ValueError, TypeError):
            raise EngineHttpError('invalid_engine_request') from None
        try:
            limits = EngineHttpLimits(**vars(limits))
        except TypeError:
            raise EngineHttpError('invalid_engine_limits') from None
        if request.method == 'POST':
            _require(parse_qsl(request.target.split('?', 1)[1])[1][1] == platform,
                     'invalid_engine_request')
        cancelled = threading.Event() if cancelled is None else cancelled
        _require(type(cancelled) is threading.Event, 'invalid_engine_request')
        _require(not cancelled.is_set(), 'engine_cancelled')
        deadline = time.monotonic() + limits.total_seconds
        watcher = None
        chunks = None
        try:
            before = _identity(endpoint)
            watcher = _Deadline(deadline)
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            watcher.attach(connection)
            connection.settimeout(min(_remaining(deadline), limits.idle_seconds))
            connection.connect(endpoint.path)
            _require(_identity(endpoint) == before, 'engine_unavailable')
            peer = self._peer_uid(connection)
            _require(type(peer) is int and peer == endpoint.owner_uid, 'engine_unavailable')
            reader = _EngineReader(connection, deadline, limits, cancelled)
            version_request = _request_bytes('GET', '/version', 'localhost', dict(_HEADERS), None)
            connection.sendall(version_request.replace(b'Connection: close\r\n',
                                                       b'Connection: keep-alive\r\n', 1))
            status, headers = _headers(reader)
            version = b''.join(_body(reader, headers, 65536, 4096))
            _require(_compatibility(ProbeResponse(status, headers, version), platform) == 'passed',
                     'engine_api_unsupported')
            _require(not any(key == 'connection' and 'close' in value.lower() for key, value in headers),
                     'engine_api_unsupported')
            _require(_identity(endpoint) == before, 'engine_unavailable')
            _require(not cancelled.is_set(), 'engine_cancelled')
            connection.settimeout(min(_remaining(deadline), limits.idle_seconds))
            connection.sendall(_request_bytes(request.method, request.target, 'localhost',
                                               dict(request.headers), request.body))
            status, headers = _headers(reader)
            chunks = _ScopedChunks(_body(reader, headers, limits.max_total_bytes, limits.max_chunks,
                                         allow_eof=request.method == 'POST'))
            result = consume(status, headers, chunks)
            _require(_identity(endpoint) == before, 'engine_unavailable')
            _require(not cancelled.is_set(), 'engine_cancelled')
            _require(time.monotonic() < deadline, 'engine_timeout')
            return result
        except EngineHttpError:
            raise
        except (OSError, ValueError, TypeError, RuntimeError, DockerWorkerError, ProbeTransportError) as error:
            if cancelled.is_set():
                code = 'engine_cancelled'
            elif time.monotonic() >= deadline or isinstance(error, TimeoutError):
                code = 'engine_timeout'
            elif isinstance(error, ProbeTransportError):
                code = 'engine_protocol'
            else:
                code = 'engine_unavailable'
            raise EngineHttpError(code) from None
        finally:
            if chunks is not None:
                chunks.close()
            if watcher is not None:
                watcher.finish()
