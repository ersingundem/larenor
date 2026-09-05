"""Private catalog image primitives; no API/IPC handler or automatic retry.

Every connection checks Engine API 1.47 on that same authenticated Unix stream.
Pull completion only means the bounded progress stream ended without an error;
the caller must journal intent before pull and inspect afterwards. Shared image
cache is never deleted or adopted as exclusive owned storage. Operator policy,
daemon image-store capacity and dispatch authorization remain caller gates.

Schema: https://docs.docker.com/reference/api/engine/version/v1.47.yaml
"""

from dataclasses import dataclass, field
import math
import re
import socket
import threading
import time
from urllib.parse import quote, urlencode

from ..services.transport import (
    ProbeResponse, ProbeTransportError, _Deadline, _Reader, _remaining, _request_bytes,
)
from .docker_probe import DockerEndpoint, _compatibility, _identity, _linux_peer_uid
from .resource_plan import ResourcePlanError, verify_resource_plan
from .worker import DockerWorkerError, _canonical, _decode


_CODES = frozenset({'invalid_image_binding', 'invalid_image_limits', 'image_protocol',
                    'image_stream_limit', 'image_pull_failed', 'image_engine_unavailable',
                    'image_timeout', 'image_cancelled', 'image_unverified', 'image_api_unsupported'})
_TOKEN = re.compile(rb"[!#$%&'*+.^_`|~0-9A-Za-z-]+\Z")


class ImageResourceError(Exception):
    def __init__(self, code='image_engine_unavailable'):
        self.code = code if code in _CODES else 'image_engine_unavailable'
        super().__init__(self.code)


def _require(value, code='image_protocol'):
    if not value:
        raise ImageResourceError(code)


@dataclass(frozen=True)
class ImagePullLimits:
    """Private operator values, not Client-supplied options or disk quotas."""

    total_seconds: float = 900.0
    idle_seconds: float = 30.0
    max_total_bytes: int = 16 * 1024 * 1024
    max_line_bytes: int = 65536
    max_events: int = 100000
    max_chunks: int = 100000

    def __post_init__(self):
        for name, maximum in (('total_seconds', 3600), ('idle_seconds', 120)):
            value = getattr(self, name)
            _require(type(value) in (int, float) and math.isfinite(value) and 0 < value <= maximum,
                     'invalid_image_limits')
        for name, maximum in (('max_total_bytes', 64 * 1024 * 1024), ('max_line_bytes', 1048576),
                              ('max_events', 1000000), ('max_chunks', 1000000)):
            value = getattr(self, name)
            _require(type(value) is int and 1 <= value <= maximum, 'invalid_image_limits')


@dataclass(frozen=True)
class _ImageBinding:
    resource_id: str
    reference: str
    platform: str
    config_digest: str
    source: tuple = field(repr=False, compare=False)


def image_binding(plan, stack, catalog, policy, resource_id):
    """Derive the private reference from the complete current catalog proposal."""
    try:
        verified = verify_resource_plan(plan, stack, catalog, policy)
        _require(type(resource_id) is str, 'invalid_image_binding')
        resource = next((item for item in verified.resources if item.resourceId == resource_id), None)
        _require(resource is not None and resource.kind == 'ensure_image', 'invalid_image_binding')
        return _ImageBinding(resource_id, resource.image.reference, resource.image.platform,
                             resource.image.configDigest, (verified, stack, catalog, policy))
    except (ResourcePlanError, ValueError, TypeError, AttributeError):
        raise ImageResourceError('invalid_image_binding') from None


def _binding(value):
    _require(type(value) is _ImageBinding, 'invalid_image_binding')
    try:
        verified = image_binding(*value.source, value.resource_id)
        _require(verified == value, 'invalid_image_binding')
        return verified
    except (ValueError, TypeError, AttributeError):
        raise ImageResourceError('invalid_image_binding') from None


@dataclass(frozen=True)
class ImageObservation:
    image_id: str
    configuration: bytes = field(repr=False)


def _inspect(value, binding):
    _require(value.get('Id') == binding.config_digest and value.get('Os') == 'linux'
             and value.get('Architecture') == binding.platform.split('/')[1], 'image_unverified')
    variant = value.get('Variant')
    _require(variant in (None, '', 'v8') if binding.platform == 'linux/arm64'
             else variant in (None, ''), 'image_unverified')
    digests = value.get('RepoDigests')
    _require(type(digests) is list and len(digests) <= 256
             and all(type(item) is str and len(item) <= 1024 for item in digests)
             and binding.reference in digests, 'image_unverified')
    _require(type(value.get('Config')) is dict, 'image_unverified')
    try:
        configuration = _canonical(value['Config'])
    except DockerWorkerError:
        raise ImageResourceError('image_unverified') from None
    return ImageObservation(binding.config_digest, configuration)


class _ImageReader(_Reader):
    def __init__(self, connection, deadline, limits, cancelled):
        super().__init__(connection, deadline)
        self.limits, self.cancelled = limits, cancelled

    def receive(self, count):
        idle_end = time.monotonic() + self.limits.idle_seconds
        while True:
            _require(not self.cancelled.is_set(), 'image_cancelled')
            left = min(self.deadline, idle_end) - time.monotonic()
            _require(left > 0, 'image_timeout')
            self.connection.settimeout(min(left, 0.25))
            try:
                data = self.connection.recv(count)
            except socket.timeout:
                continue
            _require(not self.cancelled.is_set(), 'image_cancelled')
            _require(time.monotonic() < self.deadline, 'image_timeout')
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
        _require(remaining <= max_bytes, 'image_stream_limit')
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
            _require(chunks <= max_chunks and size <= max_bytes - total, 'image_stream_limit')
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
            _require(total <= max_bytes, 'image_stream_limit')
            yield piece


def _json(data):
    try:
        return _decode(data)
    except DockerWorkerError:
        raise ImageResourceError('image_protocol') from None


def _progress(chunks, limits):
    pending = bytearray()
    count = 0
    for piece in chunks:
        pending.extend(piece)
        while True:
            at = pending.find(b'\n')
            if at < 0:
                _require(len(pending) <= limits.max_line_bytes, 'image_stream_limit')
                break
            _require(at + 1 <= limits.max_line_bytes, 'image_stream_limit')
            count += 1
            _require(count <= limits.max_events, 'image_stream_limit')
            value = _json(bytes(pending[:at]))
            del pending[:at + 1]
            _require('error' not in value and 'errorDetail' not in value, 'image_pull_failed')
            _require(bool(value) and set(value) <= {'status', 'progress', 'progressDetail', 'id', 'aux'})
            for name in ('status', 'progress', 'id'):
                _require(name not in value or type(value[name]) is str)
            for name in ('progressDetail', 'aux'):
                _require(name not in value or type(value[name]) is dict)
    _require(count > 0 and not pending)


class UnixImageEngine:
    """Narrow trusted worker dependency; never instantiate in an API process.

    No pull is initiated by inspect and no inspect is silently retried. There is
    no URL/auth option, shell/TCP fallback, image delete, prune or container API.
    A lost pull response must be reconciled by the caller using a fresh inspect.
    """

    def __init__(self, endpoint, *, limits=None, peer_uid=None):
        _require(type(endpoint) is DockerEndpoint, 'invalid_image_binding')
        self._endpoint = endpoint
        self._limits = ImagePullLimits() if limits is None else limits
        _require(type(self._limits) is ImagePullLimits, 'invalid_image_limits')
        ImagePullLimits(**vars(self._limits))
        _require(peer_uid is None or callable(peer_uid), 'invalid_image_binding')
        self._peer_uid = _linux_peer_uid if peer_uid is None else peer_uid

    def inspect(self, binding, *, cancelled=None):
        binding = _binding(binding)
        return self._exchange(binding, False, cancelled)

    def pull(self, binding, *, cancelled=None):
        binding = _binding(binding)
        return self._exchange(binding, True, cancelled)

    def _exchange(self, binding, pull, cancelled):
        cancelled = threading.Event() if cancelled is None else cancelled
        _require(type(cancelled) is threading.Event, 'invalid_image_binding')
        _require(not cancelled.is_set(), 'image_cancelled')
        # Revalidate frozen values against accidental in-process mutation too.
        limits = ImagePullLimits(**vars(self._limits))
        deadline = time.monotonic() + (limits.total_seconds if pull else min(limits.total_seconds, 30))
        watcher = None
        try:
            before = _identity(self._endpoint)
            watcher = _Deadline(deadline)
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            watcher.attach(connection)
            connection.settimeout(min(_remaining(deadline), limits.idle_seconds))
            connection.connect(self._endpoint.path)
            _require(_identity(self._endpoint) == before, 'image_engine_unavailable')
            peer = self._peer_uid(connection)
            _require(type(peer) is int and peer == self._endpoint.owner_uid, 'image_engine_unavailable')
            reader = _ImageReader(connection, deadline, limits, cancelled)
            request = _request_bytes('GET', '/version', 'localhost', {'Accept': 'application/json'}, None)
            connection.sendall(request.replace(b'Connection: close\r\n', b'Connection: keep-alive\r\n', 1))
            status, headers = _headers(reader)
            version = b''.join(_body(reader, headers, 65536, 4096))
            _require(_compatibility(ProbeResponse(status, headers, version), binding.platform) == 'passed',
                     'image_api_unsupported')
            _require(not any(key == 'connection' and 'close' in value.lower() for key, value in headers),
                     'image_api_unsupported')
            _require(_identity(self._endpoint) == before, 'image_engine_unavailable')
            _require(not cancelled.is_set(), 'image_cancelled')
            connection.settimeout(min(_remaining(deadline), limits.idle_seconds))
            target = ('/images/create?' + urlencode({'fromImage': binding.reference, 'platform': binding.platform})
                      if pull else '/images/' + quote(binding.reference, safe='') + '/json')
            connection.sendall(_request_bytes('POST' if pull else 'GET', '/v1.47' + target, 'localhost',
                                               {'Accept': 'application/json'}, None))
            status, headers = _headers(reader)
            if not pull and status == 404:
                result = None
            else:
                _require(status == 200, 'image_pull_failed' if pull else 'image_engine_unavailable')
                if pull:
                    _progress(_body(reader, headers, limits.max_total_bytes, limits.max_chunks, allow_eof=True), limits)
                    result = None
                else:
                    result = _inspect(_json(b''.join(_body(reader, headers, 1048576, 4096))), binding)
            _require(_identity(self._endpoint) == before, 'image_engine_unavailable')
            _require(not cancelled.is_set(), 'image_cancelled')
            _require(time.monotonic() < deadline, 'image_timeout')
            return result
        except ImageResourceError:
            raise
        except (OSError, ValueError, TypeError, RuntimeError, DockerWorkerError, ProbeTransportError) as error:
            if cancelled.is_set():
                code = 'image_cancelled'
            elif time.monotonic() >= deadline or isinstance(error, TimeoutError):
                code = 'image_timeout'
            elif isinstance(error, ProbeTransportError):
                code = 'image_protocol'
            else:
                code = 'image_engine_unavailable'
            raise ImageResourceError(code) from None
        finally:
            if watcher is not None:
                watcher.finish()
