"""Pure private control-network contracts; no transport, journal writes or effects.

Bindings re-derive the complete current stack/catalog/policy proposal. Intents
are trusted in-process journal inputs, not wire objects or authorization grants.
A create body is only a proposal for an already begun intent: the future bridge
must hold the journal lease and recheck actor, cancellation, daemon context and
current revision immediately before a separately authorized effect.

List replies must come from the exact generated name query, on a fully framed,
bounded authenticated Engine response. API 1.47 has no list pagination; partial
or label-filtered results cannot establish absence. A list result is NEVER a
matched ownership receipt: since API 1.28 list omits attached endpoints. A full
ID inspect is still required. Neither helper proves ongoing exclusivity, safe
bootstrap, firewall isolation, egress suitability or permission to attach.

Sources: Docker Engine 1.47 OpenAPI and Moby v27.5.1 API/types/network +
daemon/network.go. The pinned v27 schema has no EnableIPv4 create field (despite
newer documentation snapshots); IPv4 is default, IPv6 is explicitly disabled.
Default IPAM may return null maps and daemon-allocated IPv4 subnet/gateway data.
No custom Options/IPAM/ConfigFrom or deprecated CheckDuplicate is requested.
https://raw.githubusercontent.com/moby/moby/v27.5.1/api/swagger.yaml
https://raw.githubusercontent.com/moby/moby/v27.5.1/daemon/network.go
"""

from dataclasses import dataclass, field, fields
import hashlib
import ipaddress
import json
import re
from urllib.parse import urlencode

from ..services.transport import ProbeResponse
from .resource_journal import NetworkIdentity, ResourceIntent, ResourceReceipt
from .resource_models import PrepareControlNetworkResource
from .resource_plan import _wire, verify_resource_plan


MAX_LIST_BYTES = 131072
MAX_INSPECT_BYTES = 65536
MAX_NETWORKS = 128
_ID = re.compile(r'[0-9a-f]{32}\Z')
_HASH = re.compile(r'[0-9a-f]{64}\Z')
_CODES = frozenset({'invalid_network_binding', 'network_protocol', 'network_response_limit',
                    'network_conflict', 'network_multiple'})
_NETWORK_KEYS = frozenset({'Name', 'Id', 'Created', 'Scope', 'Driver', 'EnableIPv4', 'EnableIPv6',
    'IPAM', 'Internal', 'Attachable', 'Ingress', 'ConfigFrom', 'ConfigOnly', 'Containers',
    'Options', 'Labels', 'Peers', 'Services'})


class NetworkResourceError(Exception):
    """Only a static code, never an Engine value, label, address or raw error."""

    def __init__(self, code='network_protocol'):
        self.code = code if code in _CODES else 'network_protocol'
        super().__init__(self.code)


def _require(condition):
    if not condition:
        raise ValueError()


def _matches(value, expression):
    return type(value) is str and expression.fullmatch(value) is not None


def _exact(value, cls):
    return type(value) is cls and set(vars(value)) == {item.name for item in fields(cls)}


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                      allow_nan=False).encode('utf-8')


@dataclass(frozen=True, repr=False)
class NetworkBinding:
    resource: PrepareControlNetworkResource
    source: tuple = field(compare=False)


def network_binding(plan, stack, catalog, policy, resource_id):
    """Derive a fixed proposal; no name, driver or option comes from Client input."""
    try:
        _require(_matches(resource_id, _ID))
        verified = verify_resource_plan(plan, stack, catalog, policy)
        resource = next((item for item in verified.resources if item.resourceId == resource_id), None)
        _require(type(resource) is PrepareControlNetworkResource)
        return NetworkBinding(resource, (verified, stack, catalog, policy))
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise NetworkResourceError('invalid_network_binding') from None


def _binding(value):
    try:
        _require(_exact(value, NetworkBinding) and type(value.source) is tuple and len(value.source) == 4)
        selected = network_binding(*value.source, value.resource.resourceId)
        _require(_wire(value.resource) == _wire(selected.resource))
        return selected
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise NetworkResourceError('invalid_network_binding') from None


def _inputs(binding, intent, *, creating=False):
    selected = _binding(binding)
    try:
        plan, stack, catalog, policy = selected.source
        _require(_exact(intent, ResourceIntent) and _matches(intent.journal_id, _ID)
                 and _matches(intent.ownership_nonce, _ID) and _matches(intent.specification_digest, _HASH))
        _require(type(intent.resource) is PrepareControlNetworkResource
                 and _wire(intent.resource) == _wire(selected.resource))
        digest = hashlib.sha256(_canonical(selected.resource.model_dump(mode='json'))).hexdigest()
        _require(intent.specification_digest == digest)
        receipt = intent.receipt
        _require(_exact(receipt, ResourceReceipt) and type(receipt.revision) is int
                 and 2 <= receipt.revision <= 2**63 - 2)
        _require((receipt.resource_id, receipt.preparation_id, receipt.kind, receipt.plan_hash,
                  receipt.worker_policy_digest) == (selected.resource.resourceId, plan.preparationId,
                  'prepare_control_network', plan.planHash, policy.workerPolicyDigest))
        codes = {'mutating': {'effect_started'}, 'uncertain': {'effect_uncertain', 'observation_unavailable'},
                 'ready': {'resource_matched'}, 'needs_attention': {'resource_missing', 'resource_conflict',
                 'resource_multiple', 'observation_invalid'}}
        _require(type(receipt.state) is str and receipt.state in codes
                 and type(receipt.code) is str and receipt.code in codes[receipt.state]
                 and (receipt.state == 'mutating') == (receipt.revision == 2))
        _require(not creating or receipt.state == 'mutating')
        return selected, {
            'org.larenor.resource-schema': '1', 'org.larenor.core': plan.coreId,
            'org.larenor.home': plan.homeId, 'org.larenor.preparation': plan.preparationId,
            'org.larenor.resource': selected.resource.resourceId,
            'org.larenor.operation': selected.resource.operationId,
            'org.larenor.worker-journal': intent.journal_id,
            'org.larenor.ownership-nonce': intent.ownership_nonce,
            'org.larenor.specification': digest, 'org.larenor.plan': plan.planHash,
            'org.larenor.stack-plan': stack.planHash, 'org.larenor.catalog': catalog.digest,
            'org.larenor.worker-policy-version': str(policy.workerPolicyVersion),
            'org.larenor.worker-policy': policy.workerPolicyDigest,
        }
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise NetworkResourceError('invalid_network_binding') from None


def build_network_create_body(binding, intent):
    """Return immutable canonical bytes, without dispatching or granting creation."""
    selected, labels = _inputs(binding, intent, creating=True)
    return _canonical(dict(Name=selected.resource.name, Driver='bridge', Scope='local',
        Internal=True, Attachable=False, Ingress=False, ConfigOnly=False, EnableIPv6=False, Labels=labels))


def network_list_target(binding):
    """Name only: label/driver filters could hide a conflicting same-name network."""
    selected = _binding(binding)
    return '/v1.47/networks?' + urlencode({'filters': _canonical({'name': [selected.resource.name]}).decode()})


def _pairs(values):
    result = {}
    for key, value in values:
        _require(key not in result)
        result[key] = value
    return result


def _response(response, maximum, cls):
    try:
        _require(_exact(response, ProbeResponse) and type(response.body) is bytes)
        if len(response.body) > maximum:
            raise NetworkResourceError('network_response_limit')
        _require(type(response.status) is int and response.status == 200
                 and type(response.headers) is tuple and len(response.headers) <= 100)
        headers = {}
        for pair in response.headers:
            _require(type(pair) is tuple and len(pair) == 2 and all(type(item) is str for item in pair))
            key, value = pair
            _require(len(key) <= 128 and len(value) <= 8192)
            key = key.lower()
            if key in {'content-type', 'content-range', 'link'}:
                _require(key not in headers)
                headers[key] = value
        _require('content-range' not in headers and 'link' not in headers
                 and headers.get('content-type', '').lower().split(';')[0].strip() == 'application/json')
        value = json.loads(response.body, object_pairs_hook=_pairs,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        nodes = 0
        def bounded(item, depth=0):
            nonlocal nodes
            nodes += 1
            _require(depth <= 12 and nodes <= 16384)
            if type(item) is dict:
                for key, entry in item.items():
                    _require(len(key) <= 128)
                    bounded(entry, depth + 1)
            elif type(item) is list:
                for entry in item:
                    bounded(entry, depth + 1)
            elif type(item) is str:
                _require(len(item) <= 8192)
            else:
                _require(item is None or type(item) in (int, bool))
        bounded(value)
        _require(type(value) is cls)
        return value
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise NetworkResourceError('network_protocol') from None


def _empty_map(value):
    return value is None or type(value) is dict and not value


def _ipam(value, *, detailed):
    _require(type(value) is dict and set(value) <= {'Driver', 'Config', 'Options'}
             and value.get('Driver') == 'default' and _empty_map(value.get('Options')))
    configs = value.get('Config')
    if not detailed and (configs is None or configs == []):
        return
    _require(type(configs) is list and len(configs) == 1)
    config = configs[0]
    _require(type(config) is dict and set(config) <= {'Subnet', 'Gateway', 'IPRange', 'AuxiliaryAddresses'}
             and config.get('IPRange', '') == '' and _empty_map(config.get('AuxiliaryAddresses')))
    subnet = config.get('Subnet')
    _require(type(subnet) is str and len(subnet) <= 18)
    parsed = ipaddress.IPv4Network(subnet, strict=True)
    _require(str(parsed) == subnet)
    gateway = config.get('Gateway', '')
    _require(type(gateway) is str and len(gateway) <= 15)
    if gateway:
        address = ipaddress.IPv4Address(gateway)
        _require(str(address) == gateway and address in parsed
                 and address not in (parsed.network_address, parsed.broadcast_address))


def _properties(value, selected, labels, *, detailed):
    _require(type(value) is dict and set(value) <= _NETWORK_KEYS
             and value.get('Name') == selected.resource.name and _matches(value.get('Id'), _HASH)
             and value.get('Driver') == 'bridge' and value.get('Scope') == 'local'
             and value.get('Internal') is True and value.get('Attachable') is False
             and value.get('Ingress') is False and value.get('ConfigOnly') is False
             and value.get('EnableIPv6') is False and value.get('EnableIPv4', True) is True)
    _require(type(value.get('Labels')) is dict and value['Labels'] == labels
             and _empty_map(value.get('Options')))
    config_from = value.get('ConfigFrom')
    _require(type(config_from) is dict and config_from in ({}, {'Network': ''}))
    _require(value.get('Peers') is None or type(value['Peers']) is list and not value['Peers'])
    _require(_empty_map(value.get('Services')))
    if detailed:
        _require(type(value.get('Containers')) is dict and not value['Containers'])
    else:
        _require(_empty_map(value.get('Containers')))
    _ipam(value.get('IPAM'), detailed=detailed)


@dataclass(frozen=True, repr=False)
class NetworkListObservation:
    """Missing or a candidate ID only; no ownership/attachment proof."""

    state: str
    network_id: str | None = field(default=None, repr=False)


def validate_network_list(response, binding, intent, *, request_target):
    selected, labels = _inputs(binding, intent)
    if type(request_target) is not str or request_target != network_list_target(selected):
        raise NetworkResourceError('network_protocol')
    values = _response(response, MAX_LIST_BYTES, list)
    if len(values) > MAX_NETWORKS:
        raise NetworkResourceError('network_response_limit')
    try:
        for value in values:
            _require(type(value) is dict and type(value.get('Name')) is str
                     and 1 <= len(value['Name']) <= 256 and _matches(value.get('Id'), _HASH))
        matches = [value for value in values if value['Name'] == selected.resource.name]
        if len(matches) > 1:
            raise NetworkResourceError('network_multiple')
        _require(len({value['Id'] for value in values}) == len(values))
    except (ValueError, TypeError):
        raise NetworkResourceError('network_protocol') from None
    if not matches:
        return NetworkListObservation('missing')
    try:
        _properties(matches[0], selected, labels, detailed=False)
    except (ValueError, TypeError, AttributeError):
        raise NetworkResourceError('network_conflict') from None
    return NetworkListObservation('candidate', matches[0]['Id'])


def validate_network_inspect(response, binding, intent, *, expected_id):
    selected, labels = _inputs(binding, intent)
    if not _matches(expected_id, _HASH):
        raise NetworkResourceError('invalid_network_binding')
    value = _response(response, MAX_INSPECT_BYTES, dict)
    try:
        _properties(value, selected, labels, detailed=True)
        _require(value['Id'] == expected_id)
    except (ValueError, TypeError, AttributeError):
        raise NetworkResourceError('network_conflict') from None
    return NetworkIdentity(expected_id)
