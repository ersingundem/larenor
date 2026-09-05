"""Private, explicitly gated network create transport; no journal/dispatch wiring.

The body is re-derived from a bound proposal and a begun private journal intent.
The mandatory literal-True gate runs after same-socket API verification, before
one POST, with body revalidation on both sides. This trusted synchronous test
seam is not an actor/daemon/host authorization issuer or a bounded arbitrary-code
runner. The future caller must provide those real grants and own the journal
lease. No mutation belongs in DockerProbe.observe.during.

A complete 201 acknowledgement is not ownership, readiness, or permission to
attach. Lost responses must be reconciled by read-only list/inspect; this module
never retries, deletes, or updates a journal. API/IPC/CLI do not expose it.
"""

from dataclasses import dataclass, field
import math
import re

from .engine_http import EngineHttpError, EngineHttpLimits, EngineHttpRequest, VerifiedEngineHttp
from .network_resources import _inputs, build_network_create_body
from .worker import DockerWorkerError, _decode


_CODES = frozenset({'invalid_network_create_limits', 'network_create_not_authorized',
                    'network_create_protocol', 'network_create_response_limit', 'network_create_failed',
                    'network_create_unavailable', 'network_create_timeout', 'network_create_cancelled',
                    'network_create_api_unsupported', 'network_create_warning', 'invalid_network_binding'})


class NetworkCreateError(Exception):
    """Static diagnostic: never an Engine warning, body, host path or raw error."""

    def __init__(self, code='network_create_unavailable'):
        self.code = code if code in _CODES else 'network_create_unavailable'
        super().__init__(self.code)


def _require(value, code='network_create_protocol'):
    if not value:
        raise NetworkCreateError(code)


@dataclass(frozen=True)
class NetworkCreateLimits:
    total_seconds: float = 10.0
    idle_seconds: float = 2.0
    max_chunks: int = 128

    def __post_init__(self):
        for name, maximum in (('total_seconds', 10), ('idle_seconds', 2)):
            value = getattr(self, name)
            _require(type(value) in (int, float) and math.isfinite(value) and 0 < value <= maximum,
                     'invalid_network_create_limits')
        _require(type(self.max_chunks) is int and 1 <= self.max_chunks <= 128, 'invalid_network_create_limits')


@dataclass(frozen=True, repr=False)
class NetworkCreateAcknowledgement:
    """Only the reported ID; a fresh full-ID ownership inspect is still required."""

    network_id: str = field(repr=False)

    def __post_init__(self):
        _require(type(self.network_id) is str and re.fullmatch(r'[0-9a-f]{64}', self.network_id) is not None)


def _limits(value):
    _require(type(value) is NetworkCreateLimits, 'invalid_network_create_limits')
    try:
        return NetworkCreateLimits(**vars(value))
    except TypeError:
        raise NetworkCreateError('invalid_network_create_limits') from None


def _error(error):
    code = {'invalid_engine_request': 'invalid_network_binding',
            'invalid_engine_limits': 'invalid_network_create_limits',
            'engine_dispatch_denied': 'network_create_not_authorized',
            'engine_stream_limit': 'network_create_response_limit'}.get(
                error.code, error.code.replace('engine_', 'network_create_', 1))
    raise NetworkCreateError(code) from None


def _acknowledgement(status, headers, body):
    _require(status == 201, 'network_create_failed')
    _require(not any(name in {'content-range', 'link'} for name, _ in headers))
    try:
        value = _decode(body, limit=4096)
    except DockerWorkerError:
        raise NetworkCreateError('network_create_protocol') from None
    _require(set(value) == {'Id', 'Warning'} and type(value['Warning']) is str)
    _require(value['Warning'] == '', 'network_create_warning')
    return NetworkCreateAcknowledgement(value['Id'])


class UnixNetworkCreator:
    """One guarded create of the exact private proposal; no automatic retry."""

    def __init__(self, endpoint, *, limits=None, peer_uid=None):
        self._limits = _limits(NetworkCreateLimits() if limits is None else limits)
        try:
            self._http = VerifiedEngineHttp(endpoint, peer_uid=peer_uid)
        except EngineHttpError as error:
            _error(error)

    def create(self, binding, intent, *, before_dispatch=None, cancelled=None) -> NetworkCreateAcknowledgement:
        _require(callable(before_dispatch), 'network_create_not_authorized')
        selected, _ = _inputs(binding, intent, creating=True)
        expected = build_network_create_body(binding, intent)
        limits = _limits(self._limits)

        def guarded():
            _require(build_network_create_body(binding, intent) == expected, 'invalid_network_binding')
            permitted = before_dispatch() is True
            _require(build_network_create_body(binding, intent) == expected, 'invalid_network_binding')
            return permitted

        def consume(status, headers, chunks):
            _require(status == 201, 'network_create_failed')
            result = _acknowledgement(status, headers, b''.join(chunks))
            _require(build_network_create_body(binding, intent) == expected, 'invalid_network_binding')
            return result

        try:
            return self._http.exchange(
                EngineHttpRequest('POST', '/v1.47/networks/create',
                                  (('Accept', 'application/json'), ('Content-Type', 'application/json')), expected),
                consume, platform=selected.source[0].platform,
                limits=EngineHttpLimits(limits.total_seconds, limits.idle_seconds, 4096, limits.max_chunks),
                cancelled=cancelled, before_dispatch=guarded,
            )
        except EngineHttpError as error:
            _error(error)
