"""Pure Engine 1.47 local-volume observations, not execution/ownership grants.

The complete volume proposal is rederived before every operation. Journal IDs
and nonces are private expectations only: this module neither begins a durable
intent nor claims a lease. A matching inspect does not prove creation, exclusive
ownership, attachment safety, UID access or bootstrap readiness. No transport,
create/delete body, host path access or public HTTP handler is provided.

The later Engine bridge must bind these already-framed bytes to its authenticated
daemon and exact generated target. A 201 create reply or 404 inspect reply is
never treated as a matching receipt. Local volumes have no immutable Engine ID;
even exact labels can be copied by another Docker administrator.

Schema: https://raw.githubusercontent.com/moby/moby/v27.5.1/api/swagger.yaml
The required Mountpoint is checked only for bounded text then discarded. It is
never used as an inode identity, capacity measurement or path to open.
"""

from dataclasses import dataclass, field, fields
import hashlib
import json
import re

from ..services.transport import ProbeResponse
from .resource_plan import _wire
from .volume_plan import verify_volume_plan


MAX_INSPECT_BYTES = 65536
_ID = re.compile(r'[0-9a-f]{32}\Z')
_VOLUME_KEYS = frozenset({'Name', 'Driver', 'Scope', 'Options', 'Labels',
    'Mountpoint', 'CreatedAt', 'Status', 'ClusterVolume', 'UsageData'})


def _require(value):
    if not value:
        raise ValueError()


def _identity(value):
    return type(value) is str and _ID.fullmatch(value) is not None


def _exact(value, cls):
    return type(value) is cls and set(vars(value)) == {item.name for item in fields(cls)}


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                      allow_nan=False).encode('utf-8')


class VolumeResourceError(Exception):
    def __init__(self, code='volume_protocol'):
        self.code = code if code in {
            'invalid_volume_binding', 'volume_protocol', 'volume_response_limit',
            'volume_conflict',
        } else 'volume_protocol'
        super().__init__(self.code)


@dataclass(frozen=True, repr=False)
class VolumeBinding:
    resource_id: str
    resource: object
    source: tuple = field(compare=False)
    journal_id: str
    ownership_nonce: str


def volume_binding(plan, stack, catalog, policy, resource_id, *, journal_id, ownership_nonce):
    """Local expectation only; opaque IDs must later come from a volume journal."""
    try:
        _require(all(_identity(value) for value in (resource_id, journal_id, ownership_nonce)))
        verified = verify_volume_plan(plan, stack, catalog, policy)
        resource = next((item for item in verified.resources if item.resourceId == resource_id), None)
        _require(resource is not None)
        return VolumeBinding(resource_id, resource, (verified, stack, catalog, policy),
                             journal_id, ownership_nonce)
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise VolumeResourceError('invalid_volume_binding') from None


def _binding(value):
    try:
        _require(_exact(value, VolumeBinding) and type(value.source) is tuple and len(value.source) == 4)
        selected = volume_binding(*value.source, value.resource_id,
            journal_id=value.journal_id, ownership_nonce=value.ownership_nonce)
        _require(_wire(value.resource) == _wire(selected.resource))
        return selected
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise VolumeResourceError('invalid_volume_binding') from None


def volume_inspect_target(binding):
    selected = _binding(binding)
    return '/v1.47/volumes/' + selected.resource.name


def volume_expected_labels(binding):
    """Fresh mapping, no Client labels/options and no permission to create."""
    selected = _binding(binding)
    plan, _, _, _ = selected.source
    resource = selected.resource
    return {
        'org.larenor.volume-schema': '1', 'org.larenor.core': plan.coreId,
        'org.larenor.home': plan.homeId, 'org.larenor.preparation': plan.preparationId,
        'org.larenor.resource': resource.resourceId, 'org.larenor.operation': resource.operationId,
        'org.larenor.installation': resource.installationId,
        'org.larenor.service': resource.serviceId, 'org.larenor.child-plan': resource.childPlanHash,
        'org.larenor.volume-plan': plan.planHash, 'org.larenor.stack-plan': plan.stackPlanHash,
        'org.larenor.catalog': plan.catalogDigest,
        'org.larenor.worker-policy-version': str(plan.workerPolicyVersion),
        'org.larenor.worker-policy': plan.workerPolicyDigest,
        'org.larenor.volume-journal': selected.journal_id,
        'org.larenor.ownership-nonce': selected.ownership_nonce,
        'org.larenor.specification': hashlib.sha256(
            _canonical(resource.model_dump(mode='json'))).hexdigest(),
    }


def _pairs(values):
    result = {}
    for key, value in values:
        _require(key not in result)
        result[key] = value
    return result


def _response(response):
    try:
        _require(_exact(response, ProbeResponse) and type(response.body) is bytes)
        if len(response.body) > MAX_INSPECT_BYTES:
            raise VolumeResourceError('volume_response_limit')
        _require(type(response.status) is int and response.status == 200
                 and type(response.headers) is tuple and len(response.headers) <= 100)
        headers = {}
        for pair in response.headers:
            _require(type(pair) is tuple and len(pair) == 2
                     and all(type(item) is str for item in pair))
            key, value = pair
            _require(1 <= len(key) <= 128 and len(value) <= 8192
                     and re.fullmatch(r'[!#$%&\x27*+.^_`|~0-9A-Za-z-]+', key) is not None
                     and not any(ord(char) < 32 or ord(char) == 127 for char in value))
            key = key.lower()
            if key in {'content-type', 'content-range', 'link', 'content-length',
                       'transfer-encoding', 'content-encoding'}:
                _require(key not in headers)
                headers[key] = value
        _require('content-range' not in headers and 'link' not in headers
                 and headers.get('content-type', '').lower().split(';')[0].strip() == 'application/json')
        _require(headers.get('content-encoding', 'identity').lower() == 'identity'
                 and headers.get('transfer-encoding', 'chunked').lower() == 'chunked'
                 and not ('content-length' in headers and 'transfer-encoding' in headers))
        if 'content-length' in headers:
            length = headers['content-length']
            _require(re.fullmatch(r'[0-9]{1,20}', length) is not None
                     and int(length) == len(response.body))
        value = json.loads(response.body.decode('utf-8'), object_pairs_hook=_pairs,
            parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        nodes = 0
        def bounded(item, depth=0):
            nonlocal nodes
            nodes += 1
            _require(depth <= 12 and nodes <= 4096)
            if type(item) is dict:
                for key, entry in item.items():
                    _require(len(key) <= 128)
                    bounded(entry, depth + 1)
            elif type(item) is list:
                for entry in item:
                    bounded(entry, depth + 1)
            elif type(item) is str:
                _require(len(item) <= 4096 and not any(0xd800 <= ord(c) <= 0xdfff for c in item))
            else:
                _require(item is None or type(item) in (int, bool))
        bounded(value)
        _require(type(value) is dict)
        return value
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise VolumeResourceError('volume_protocol') from None


@dataclass(frozen=True, repr=False)
class VolumeObservation:
    """Matched labels at observation time, with no host path or execution state."""
    resource_id: str
    name: str
    plan_hash: str
    labels_digest: str
    state: str = 'labels_matched'


def _plain_text(value):
    return type(value) is str and 1 <= len(value) <= 4096 and not any(
        ord(char) < 32 or ord(char) == 127 for char in value)


def validate_volume_inspect(response, binding, *, request_target):
    selected = _binding(binding)
    if type(request_target) is not str or request_target != volume_inspect_target(selected):
        raise VolumeResourceError('volume_protocol')
    value = _response(response)
    labels = volume_expected_labels(selected)
    try:
        _require(set(value) <= _VOLUME_KEYS and value.get('Name') == selected.resource.name
                 and value.get('Driver') == 'local' and value.get('Scope') == 'local'
                 and 'Options' in value and (value['Options'] is None or
                     type(value['Options']) is dict and not value['Options'])
                 and type(value.get('Labels')) is dict and value['Labels'] == labels
                 and _plain_text(value.get('Mountpoint')))
        _require('CreatedAt' not in value or _plain_text(value['CreatedAt']))
        _require(value.get('Status') is None or type(value['Status']) is dict and not value['Status'])
        _require(value.get('ClusterVolume') is None and value.get('UsageData') is None)
    except (ValueError, TypeError, AttributeError):
        raise VolumeResourceError('volume_conflict') from None
    return VolumeObservation(selected.resource_id, selected.resource.name,
        selected.source[0].planHash, hashlib.sha256(_canonical(labels)).hexdigest())
