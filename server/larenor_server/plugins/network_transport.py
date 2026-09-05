"""Private read-only control-network adapter; no journal writes or effects.

Only an exact generated name-list and full-ID inspect can be dispatched, each
after API/platform verification on its own authenticated Unix connection. A
list result is missing or a candidate, never an ownership receipt. Inspect is a
point-in-time property observation, not daemon-context, actor or attach/create
authority. The caller owns the intent's journal lease and revision checks.

No raw request, API/IPC/CLI, network create/attach, automatic inspect or retry is
exposed. This private ten-second transport is not wired to five-second IPC jobs.
"""

from dataclasses import dataclass
import math
import re

from ..services.transport import ProbeResponse
from .engine_http import EngineHttpError, EngineHttpLimits, EngineHttpRequest, VerifiedEngineHttp
from .network_resources import (
    MAX_INSPECT_BYTES, MAX_LIST_BYTES, NetworkBinding, NetworkListObservation,
    NetworkResourceError, _inputs, network_list_target, validate_network_inspect, validate_network_list,
)
from .resource_journal import NetworkIdentity, ResourceIntent


_CODES = frozenset({'invalid_network_limits', 'network_engine_unavailable', 'network_timeout',
                    'network_cancelled', 'network_api_unsupported'})


class NetworkTransportError(Exception):
    """Static transport diagnostic without host paths or Engine response data."""

    def __init__(self, code='network_engine_unavailable'):
        self.code = code if code in _CODES else 'network_engine_unavailable'
        super().__init__(self.code)


@dataclass(frozen=True)
class NetworkReadLimits:
    """Trusted bounds may only reduce these defaults; never Client options."""

    total_seconds: float = 10.0
    idle_seconds: float = 2.0
    max_chunks: int = 4096

    def __post_init__(self):
        for name, maximum in (('total_seconds', 10), ('idle_seconds', 2)):
            value = getattr(self, name)
            if type(value) not in (int, float) or not math.isfinite(value) or not 0 < value <= maximum:
                raise NetworkTransportError('invalid_network_limits')
        if type(self.max_chunks) is not int or not 1 <= self.max_chunks <= 4096:
            raise NetworkTransportError('invalid_network_limits')


def _limits(value):
    if type(value) is not NetworkReadLimits:
        raise NetworkTransportError('invalid_network_limits')
    try:
        return NetworkReadLimits(**vars(value))
    except TypeError:
        raise NetworkTransportError('invalid_network_limits') from None


def _transport_error(error):
    pure_codes = {'invalid_engine_request': 'invalid_network_binding',
                  'engine_protocol': 'network_protocol', 'engine_stream_limit': 'network_response_limit'}
    if error.code in pure_codes:
        raise NetworkResourceError(pure_codes[error.code]) from None
    code = {'invalid_engine_limits': 'invalid_network_limits',
            'engine_unavailable': 'network_engine_unavailable'}.get(
                error.code, error.code.replace('engine_', 'network_', 1))
    raise NetworkTransportError(code) from None


class UnixNetworkEngine:
    """Private worker dependency with exactly two read-only operations."""

    def __init__(self, endpoint, *, limits=None, peer_uid=None):
        self._limits = _limits(NetworkReadLimits() if limits is None else limits)
        try:
            self._http = VerifiedEngineHttp(endpoint, peer_uid=peer_uid)
        except EngineHttpError as error:
            _transport_error(error)

    def list(self, binding: NetworkBinding, intent: ResourceIntent, *, cancelled=None) -> NetworkListObservation:
        return self._exchange(binding, intent, None, cancelled)

    def inspect(self, binding: NetworkBinding, intent: ResourceIntent, network_id: str, *,
                cancelled=None) -> NetworkIdentity:
        if type(network_id) is not str or re.fullmatch(r'[0-9a-f]{64}', network_id) is None:
            raise NetworkResourceError('invalid_network_binding')
        return self._exchange(binding, intent, network_id, cancelled)

    def _exchange(self, binding, intent, network_id, cancelled):
        selected, _ = _inputs(binding, intent)
        limits = _limits(self._limits)
        target = (network_list_target(selected) if network_id is None
                  else '/v1.47/networks/' + network_id)
        maximum = MAX_LIST_BYTES if network_id is None else MAX_INSPECT_BYTES

        def consume(status, headers, chunks):
            if status != 200:
                raise NetworkTransportError('network_engine_unavailable')
            # Preserve actual framing metadata; the pure validator must also
            # reject partial/paginated envelopes rather than certify absence.
            response = ProbeResponse(status, headers, b''.join(chunks))
            if network_id is None:
                return validate_network_list(response, binding, intent, request_target=target)
            return validate_network_inspect(response, binding, intent, expected_id=network_id)

        try:
            return self._http.exchange(
                EngineHttpRequest('GET', target), consume, platform=selected.source[0].platform,
                limits=EngineHttpLimits(limits.total_seconds, limits.idle_seconds, maximum, limits.max_chunks),
                cancelled=cancelled,
            )
        except EngineHttpError as error:
            _transport_error(error)
