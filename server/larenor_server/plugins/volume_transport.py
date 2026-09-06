"""Private read-only generated-volume inspect over authenticated Unix HTTP.

The same stream checks API/platform before one bounded inspect. Matching labels
are a point-in-time observation, not creation, exclusivity, UID access, bootstrap
readiness or an effect grant. No list/create/delete, retry, public route or worker
wiring is provided. The caller owns current journal/source authority.
"""
from dataclasses import dataclass
import math

from ..services.transport import ProbeResponse
from .engine_http import EngineHttpError, EngineHttpLimits, EngineHttpRequest, VerifiedEngineHttp
from .volume_resources import (
    MAX_INSPECT_BYTES, VolumeBinding, VolumeObservation, VolumeResourceError,
    _binding, validate_volume_inspect, volume_expected_labels, volume_inspect_target,
)

_CODES = frozenset({'invalid_volume_limits', 'volume_engine_unavailable', 'volume_timeout',
                    'volume_cancelled', 'volume_api_unsupported'})


class VolumeTransportError(Exception):
    """Static diagnostic: no socket path, labels or raw Engine response."""

    def __init__(self, code='volume_engine_unavailable'):
        self.code = code if code in _CODES else 'volume_engine_unavailable'
        super().__init__(self.code)


@dataclass(frozen=True)
class VolumeReadLimits:
    """Trusted bounds may only reduce these defaults; never Client options."""

    total_seconds: float = 10.0
    idle_seconds: float = 2.0
    max_chunks: int = 4096

    def __post_init__(self):
        for name, maximum in (('total_seconds', 10), ('idle_seconds', 2)):
            value = getattr(self, name)
            if type(value) not in (int, float) or not math.isfinite(value) or not 0 < value <= maximum:
                raise VolumeTransportError('invalid_volume_limits')
        if type(self.max_chunks) is not int or not 1 <= self.max_chunks <= 4096:
            raise VolumeTransportError('invalid_volume_limits')


def _limits(value):
    if type(value) is not VolumeReadLimits:
        raise VolumeTransportError('invalid_volume_limits')
    try:
        return VolumeReadLimits(**vars(value))
    except TypeError:
        raise VolumeTransportError('invalid_volume_limits') from None


def _transport_error(error):
    pure_codes = {'invalid_engine_request': 'invalid_volume_binding',
                  'engine_protocol': 'volume_protocol', 'engine_stream_limit': 'volume_response_limit'}
    if error.code in pure_codes:
        raise VolumeResourceError(pure_codes[error.code]) from None
    code = {'invalid_engine_limits': 'invalid_volume_limits',
            'engine_unavailable': 'volume_engine_unavailable'}.get(
                error.code, error.code.replace('engine_', 'volume_', 1))
    raise VolumeTransportError(code) from None


class UnixVolumeReader:
    """Private worker dependency: exactly one read-only operation."""

    def __init__(self, endpoint, *, limits=None, peer_uid=None):
        self._limits = _limits(VolumeReadLimits() if limits is None else limits)
        try:
            self._http = VerifiedEngineHttp(endpoint, peer_uid=peer_uid)
        except EngineHttpError as error:
            _transport_error(error)

    def inspect(self, binding: VolumeBinding, *, cancelled=None) -> VolumeObservation:
        selected = _binding(binding)
        limits = _limits(self._limits)
        target = volume_inspect_target(selected)
        labels = volume_expected_labels(selected)

        def consume(status, headers, chunks):
            if status != 200:
                raise VolumeTransportError('volume_engine_unavailable')
            # Preserve framing metadata so the pure validator also rejects
            # partial/encoded replies; Mountpoint is validated then discarded.
            response = ProbeResponse(status, headers, b''.join(chunks))
            result = validate_volume_inspect(response, binding, request_target=target)
            # Keep final source/nonce validation inside the transport's last
            # deadline/cancellation/socket checks, before any result is returned.
            if volume_expected_labels(binding) != labels:
                raise VolumeResourceError('invalid_volume_binding')
            return result

        try:
            return self._http.exchange(
                EngineHttpRequest('GET', target), consume, platform=selected.source[0].platform,
                limits=EngineHttpLimits(limits.total_seconds, limits.idle_seconds,
                                        MAX_INSPECT_BYTES, limits.max_chunks),
                cancelled=cancelled,
            )
        except EngineHttpError as error:
            _transport_error(error)
