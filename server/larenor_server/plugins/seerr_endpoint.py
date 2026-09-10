"""Derive one private Seerr endpoint from a fresh managed-container read."""

from dataclasses import dataclass, fields
import ipaddress
import json
import math
import re
import socket

from .catalog import load_catalog
from .managed_container import ManagedContainerBinding, managed_container_matches
from .stack_plan import MediaStackPlan, verify_media_stack_plan


_ID = re.compile(r'[0-9a-f]{64}\Z')
_NETWORK_NAME = re.compile(r'larenor-control-[0-9a-f]{32}\Z')
_PRIVATE_V4 = tuple(ipaddress.ip_network(value) for value in (
    '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16',
))
_CODES = frozenset({
    'seerr_endpoint_untrusted', 'seerr_endpoint_unavailable',
    'invalid_seerr_endpoint_limits',
})


class SeerrEndpointError(Exception):
    def __init__(self, code='seerr_endpoint_untrusted'):
        self.code = code if code in _CODES else 'seerr_endpoint_untrusted'
        super().__init__(self.code)

    def __repr__(self):
        return f'SeerrEndpointError({self.code!r})'


def _private_address(value):
    if type(value) is not str or len(value) > 15:
        raise ValueError()
    address = ipaddress.IPv4Address(value)
    if str(address) != value or not any(address in network for network in _PRIVATE_V4):
        raise ValueError()
    return address


@dataclass(frozen=True, repr=False)
class SeerrEndpointProof:
    container_id: str
    network_id: str
    address: str
    port: int
    plan_hash: str

    def __post_init__(self):
        if (type(self.container_id) is not str or _ID.fullmatch(self.container_id) is None
                or type(self.network_id) is not str or _ID.fullmatch(self.network_id) is None
                or type(self.plan_hash) is not str or _ID.fullmatch(self.plan_hash) is None
                or type(self.port) is not int or self.port != 5055):
            raise SeerrEndpointError()
        try:
            _private_address(self.address)
        except (ValueError, ipaddress.AddressValueError):
            raise SeerrEndpointError() from None

    def __repr__(self):
        return 'SeerrEndpointProof(<private>)'


@dataclass(frozen=True, repr=False)
class OpenSeerrEndpoint:
    connection: object
    proof: SeerrEndpointProof

    def __repr__(self):
        return 'OpenSeerrEndpoint(<private>)'


def _exact(value, cls):
    return type(value) is cls and set(vars(value)) == {item.name for item in fields(cls)}


def prove_seerr_endpoint(observed, binding, stack, expected_container_id):
    """Return only a numeric endpoint tied to the exact journaled container."""
    try:
        if (type(expected_container_id) is not str or _ID.fullmatch(expected_container_id) is None
                or type(binding) is not ManagedContainerBinding
                or type(stack) is not MediaStackPlan
                or not managed_container_matches(observed, binding)
                or observed.get('Id') != expected_container_id):
            raise ValueError()
        selected = verify_media_stack_plan(stack, load_catalog())
        component = next(item for item in selected.components if item.serviceId == 'seerr')
        body = json.loads(binding.specification)
        if (body['Labels']['org.larenor.installation'] != component.installationId
                or _NETWORK_NAME.fullmatch(body['HostConfig']['NetworkMode']) is None
                or component.plan.health.profile != 'seerr_public'
                or component.plan.health.path != '/api/v1/settings/public'
                or component.plan.health.port != 5055):
            raise ValueError()
        listeners = component.plan.network.listeners
        if (len(listeners) != 1 or listeners[0].protocol != 'tcp'
                or listeners[0].purpose != 'web' or listeners[0].port != 5055):
            raise ValueError()
        state = observed.get('State')
        if (type(state) is not dict or state.get('Status') != 'running'
                or state.get('Running') is not True
                or any(state.get(key) is True for key in ('Paused', 'Restarting', 'Dead'))):
            raise ValueError()
        networks = (observed.get('NetworkSettings') or {}).get('Networks')
        if type(networks) is not dict or set(networks) != {body['HostConfig']['NetworkMode']}:
            raise ValueError()
        attached = networks[body['HostConfig']['NetworkMode']]
        prefix = attached.get('IPPrefixLen')
        if (type(attached) is not dict or attached.get('NetworkID') != binding.network_id
                or type(prefix) is not int or not 8 <= prefix <= 30):
            raise ValueError()
        address = _private_address(attached.get('IPAddress'))
        network = ipaddress.ip_network(f'{address}/{prefix}', strict=False)
        gateway_value = attached.get('Gateway')
        if type(gateway_value) is not str or len(gateway_value) > 15:
            raise ValueError()
        if gateway_value:
            gateway = _private_address(gateway_value)
            if (gateway not in network
                    or gateway in {address, network.network_address,
                                   network.broadcast_address}):
                raise ValueError()
        proof = SeerrEndpointProof(
            expected_container_id, binding.network_id, str(address), 5055, selected.planHash,
        )
        if not _exact(proof, SeerrEndpointProof):
            raise ValueError()
        return proof
    except (ValueError, TypeError, AttributeError, KeyError, StopIteration,
            json.JSONDecodeError, ipaddress.AddressValueError, SeerrEndpointError):
        raise SeerrEndpointError('seerr_endpoint_untrusted') from None


def open_seerr_endpoint(observed, binding, stack, expected_container_id, *, timeout=5.0):
    """Open one numeric TCP stream; no DNS, alternate address, proxy or retry."""
    if (type(timeout) not in (int, float) or not math.isfinite(timeout)
            or not 0 < timeout <= 10):
        raise SeerrEndpointError('invalid_seerr_endpoint_limits')
    proof = prove_seerr_endpoint(observed, binding, stack, expected_container_id)
    connection = None
    try:
        connection = socket.socket(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP)
        connection.settimeout(float(timeout))
        connection.connect((proof.address, proof.port))
        return OpenSeerrEndpoint(connection, proof)
    except (OSError, RuntimeError, TypeError, ValueError):
        if connection is not None:
            try:
                connection.close()
            except OSError:
                pass
        raise SeerrEndpointError('seerr_endpoint_unavailable') from None
