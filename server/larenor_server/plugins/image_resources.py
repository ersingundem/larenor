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
import threading
from urllib.parse import quote, urlencode

from .docker_probe import DockerEndpoint, _linux_peer_uid
from .engine_http import EngineHttpError, EngineHttpLimits, EngineHttpRequest, VerifiedEngineHttp
from .resource_plan import ResourcePlanError, verify_resource_plan
from .worker import DockerWorkerError, _canonical, _decode


_CODES = frozenset({'invalid_image_binding', 'invalid_image_limits', 'image_protocol',
                    'image_stream_limit', 'image_pull_failed', 'image_engine_unavailable',
                    'image_timeout', 'image_cancelled', 'image_unverified', 'image_api_unsupported'})


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
        target = ('/images/create?' + urlencode({'fromImage': binding.reference, 'platform': binding.platform})
                  if pull else '/images/' + quote(binding.reference, safe='') + '/json')

        def consume(status, _headers, chunks):
            if not pull and status == 404:
                return None
            _require(status == 200, 'image_pull_failed' if pull else 'image_engine_unavailable')
            if pull:
                _progress(chunks, limits)
                return None
            return _inspect(_json(b''.join(chunks)), binding)

        try:
            request = EngineHttpRequest('POST' if pull else 'GET', '/v1.47' + target)
            transport_limits = EngineHttpLimits(
                limits.total_seconds if pull else min(limits.total_seconds, 30), limits.idle_seconds,
                limits.max_total_bytes if pull else 1048576, limits.max_chunks if pull else 4096,
            )
            return VerifiedEngineHttp(self._endpoint, peer_uid=self._peer_uid).exchange(
                request, consume, platform=binding.platform, limits=transport_limits, cancelled=cancelled,
            )
        except EngineHttpError as error:
            code = {'invalid_engine_request': 'invalid_image_binding',
                    'invalid_engine_limits': 'invalid_image_limits',
                    'engine_unavailable': 'image_engine_unavailable'}.get(
                        error.code, error.code.replace('engine_', 'image_', 1))
            raise ImageResourceError(code) from None
