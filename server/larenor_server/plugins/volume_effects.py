"""Private local-volume probe/CREATE protocol; no installer or runtime grant.

Only a strict, begun VolumeCreateIntent reaches this transport. The synchronous
literal-True callback runs after /version on the SAME verified Unix connection,
with source/body checks on both sides. It is a trusted in-process seam, not a
real actor/session/daemon-incarnation or storage-budget authorization issuer.
The caller owns the complete locked journal lease and those future grants.

404 is absence only for the exact generated GET with a complete framed, bounded
JSON error. The existing read-only reader's non-200 policy is unchanged. A 201
reply may describe an already existing volume; this module returns an ACK type,
never a VolumeObservation. Fresh GET reconciliation and bootstrap remain required.
There are no retry, delete, host Mountpoint access, subprocess or container calls.
"""
from dataclasses import dataclass
import math

from ..services.transport import ProbeResponse
from .engine_http import EngineHttpError, EngineHttpLimits, EngineHttpRequest, VerifiedEngineHttp
from .resource_journal import _canonical, _digest, _MAX_REVISION
from .volume_create_journal import VolumeCreateIntent, VolumeCreateReceipt, _exact
from .volume_resources import (
    MAX_INSPECT_BYTES, VolumeResourceError, _binding, _response,
    volume_expected_labels, volume_inspect_target, validate_volume_inspect,
)


_CODES = frozenset({'invalid_volume_binding', 'invalid_volume_effect_limits',
    'volume_create_not_authorized', 'volume_protocol', 'volume_response_limit',
    'volume_engine_unavailable', 'volume_timeout', 'volume_cancelled', 'volume_api_unsupported'})


class VolumeEffectError(Exception):
    def __init__(self, code='volume_engine_unavailable'):
        self.code = code if code in _CODES else 'volume_engine_unavailable'
        super().__init__(self.code)


def _require(value, code='invalid_volume_binding'):
    if not value:
        raise VolumeEffectError(code)


@dataclass(frozen=True)
class VolumeEffectLimits:
    total_seconds: float = 10.0
    idle_seconds: float = 2.0
    max_chunks: int = 4096

    def __post_init__(self):
        _require(all(type(v) in (int, float) and math.isfinite(v) for v in (
            self.total_seconds, self.idle_seconds))
            and 0 < self.idle_seconds <= 2 and self.idle_seconds <= self.total_seconds <= 10
            and type(self.max_chunks) is int and 1 <= self.max_chunks <= 4096,
            'invalid_volume_effect_limits')


@dataclass(frozen=True, repr=False)
class VolumeAbsent:
    resource_id: str
    labels_digest: str


@dataclass(frozen=True, repr=False)
class VolumeCreateAcknowledgement:
    resource_id: str
    labels_digest: str


def _inputs(intent, *, creating=False):
    """Shape/rederived binding only; the composition checks the locked journal."""
    try:
        _require(_exact(intent, VolumeCreateIntent) and _exact(intent.receipt, VolumeCreateReceipt))
        binding = _binding(intent.binding)
        plan, _, _, policy = binding.source
        receipt = intent.receipt
        states = {'mutating': {'volume_create_started'},
                  'uncertain': {'volume_create_uncertain', 'volume_observation_unavailable'}}
        _require(receipt.state in states and receipt.code in states[receipt.state]
            and type(receipt.revision) is int and 2 <= receipt.revision < _MAX_REVISION
            and (receipt.revision == 2) == (receipt.state == 'mutating')
            and (not creating or receipt.state == 'mutating'))
        expected = VolumeCreateReceipt(binding.resource_id, plan.preparationId,
            binding.resource.operationId, plan.planHash, policy.workerPolicyDigest,
            receipt.state, receipt.revision, receipt.code)
        _require(receipt == expected
            and intent.specification_digest == _digest(binding.resource.model_dump(mode='json')))
        return binding, volume_expected_labels(binding)
    except (ValueError, TypeError, AttributeError, RecursionError, VolumeResourceError):
        raise VolumeEffectError('invalid_volume_binding') from None


def build_volume_create_body(intent):
    binding, labels = _inputs(intent, creating=True)
    body = _canonical({'Name': binding.resource.name, 'Driver': 'local', 'DriverOpts': {}, 'Labels': labels})
    _require(len(body) <= 4096)
    return body


class UnixVolumeCreator:
    def __init__(self, endpoint, *, limits=None, peer_uid=None):
        self._limits = VolumeEffectLimits() if limits is None else limits
        self._http = VerifiedEngineHttp(endpoint, peer_uid=peer_uid)

    def _exchange(self, intent, request, consume, *, cancelled=None, before_dispatch=None):
        binding, _ = _inputs(intent)
        _require(type(self._limits) is VolumeEffectLimits, 'invalid_volume_effect_limits')
        try:
            limits = VolumeEffectLimits(**vars(self._limits))
        except TypeError:
            raise VolumeEffectError('invalid_volume_effect_limits') from None
        try:
            return self._http.exchange(request, consume, platform=binding.source[0].platform,
                limits=EngineHttpLimits(limits.total_seconds, limits.idle_seconds,
                    MAX_INSPECT_BYTES, limits.max_chunks), cancelled=cancelled,
                before_dispatch=before_dispatch)
        except EngineHttpError as error:
            code = {'engine_protocol': 'volume_protocol', 'engine_response_limit': 'volume_response_limit',
                'engine_timeout': 'volume_timeout', 'engine_cancelled': 'volume_cancelled',
                'engine_api_unsupported': 'volume_api_unsupported',
                'engine_dispatch_denied': 'volume_create_not_authorized'}.get(error.code, 'volume_engine_unavailable')
            raise VolumeEffectError(code) from None

    def probe(self, intent, *, cancelled=None):
        binding, labels = _inputs(intent)
        target = volume_inspect_target(binding)
        def consume(status, headers, chunks):
            raw = b''.join(chunks)
            _require(status in (200, 404), 'volume_engine_unavailable')
            if status == 200:
                result = validate_volume_inspect(ProbeResponse(status, headers, raw), binding, request_target=target)
            else:
                # Reuse the bounded JSON/framing validator, not its observation
                # type. The real HTTP status was checked above and remains 404.
                value = _response(ProbeResponse(200, headers, raw))
                _require(set(value) == {'message'} and type(value['message']) is str
                         and 1 <= len(value['message']) <= 4096, 'volume_protocol')
                result = VolumeAbsent(binding.resource_id, _digest(labels))
            _require(_inputs(intent)[1] == labels)
            return result
        return self._exchange(intent, EngineHttpRequest('GET', target), consume, cancelled=cancelled)

    def create(self, intent, *, before_dispatch=None, cancelled=None):
        _require(callable(before_dispatch), 'volume_create_not_authorized')
        binding, labels = _inputs(intent, creating=True)
        body = build_volume_create_body(intent)
        def gate():
            _require(build_volume_create_body(intent) == body)
            allowed = before_dispatch() is True
            _require(build_volume_create_body(intent) == body)
            return allowed
        def consume(status, headers, chunks):
            raw = b''.join(chunks)
            _require(status == 201, 'volume_engine_unavailable')
            # The CREATE response uses the Volume JSON shape. Validate its
            # properties but discard the local validator's observation result:
            # a CREATE acknowledgement is never a fresh GET observation.
            validate_volume_inspect(ProbeResponse(200, headers, raw), binding,
                                    request_target=volume_inspect_target(binding))
            _require(build_volume_create_body(intent) == body)
            return VolumeCreateAcknowledgement(binding.resource_id, _digest(labels))
        return self._exchange(intent,
            EngineHttpRequest('POST', '/v1.47/volumes/create',
                (('Accept', 'application/json'), ('Content-Type', 'application/json')), body),
            consume, cancelled=cancelled, before_dispatch=gate)
