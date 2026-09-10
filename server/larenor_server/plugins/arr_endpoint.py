"""Derive a private Sonarr/Radarr endpoint from a fresh managed-container read."""

import ipaddress
import json
import math
import re
import socket
from dataclasses import dataclass, fields

from .catalog import load_catalog
from .managed_container import ManagedContainerBinding, managed_container_matches
from .stack_plan import MediaStackPlan, verify_media_stack_plan

_ID = re.compile(r'[0-9a-f]{64}\Z')
_NETWORK = re.compile(r'larenor-control-[0-9a-f]{32}\Z')
_PRIVATE = tuple(
    ipaddress.ip_network(x) for x in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')
)
_PORTS = {'sonarr': 8989, 'radarr': 7878}


class ArrEndpointError(Exception):
    def __init__(self, code='arr_endpoint_untrusted'):
        self.code = (
            code
            if code
            in {
                'arr_endpoint_untrusted',
                'arr_endpoint_unavailable',
                'invalid_arr_endpoint_limits',
            }
            else 'arr_endpoint_untrusted'
        )
        super().__init__(self.code)

    def __repr__(self):
        return f'ArrEndpointError({self.code!r})'


def _address(value):
    if type(value) is not str or len(value) > 15:
        raise ValueError()
    result = ipaddress.IPv4Address(value)
    if str(result) != value or not any(result in net for net in _PRIVATE):
        raise ValueError()
    return result


@dataclass(frozen=True, repr=False)
class ArrEndpointProof:
    service_id: str
    container_id: str
    network_id: str
    address: str
    port: int
    plan_hash: str

    def __post_init__(self):
        try:
            if (
                self.service_id not in _PORTS
                or type(self.container_id) is not str
                or not _ID.fullmatch(self.container_id)
                or type(self.network_id) is not str
                or not _ID.fullmatch(self.network_id)
                or type(self.plan_hash) is not str
                or not _ID.fullmatch(self.plan_hash)
                or type(self.port) is not int
                or self.port != _PORTS[self.service_id]
            ):
                raise ValueError()
            _address(self.address)
        except ValueError:
            raise ArrEndpointError() from None

    def __repr__(self):
        return 'ArrEndpointProof(<private>)'


@dataclass(frozen=True, repr=False)
class OpenArrEndpoint:
    connection: object
    proof: ArrEndpointProof

    def __repr__(self):
        return 'OpenArrEndpoint(<private>)'


def prove_arr_endpoint(observed, binding, stack, expected_container_id, service_id):
    try:
        if (
            service_id not in _PORTS
            or type(expected_container_id) is not str
            or not _ID.fullmatch(expected_container_id)
            or type(binding) is not ManagedContainerBinding
            or type(stack) is not MediaStackPlan
            or not managed_container_matches(observed, binding)
            or observed.get('Id') != expected_container_id
        ):
            raise ValueError()
        selected = verify_media_stack_plan(stack, load_catalog())
        component = next(x for x in selected.components if x.serviceId == service_id)
        body = json.loads(binding.specification)
        port = _PORTS[service_id]
        if (
            body['Labels']['org.larenor.installation'] != component.installationId
            or not _NETWORK.fullmatch(body['HostConfig']['NetworkMode'])
            or component.plan.health.profile != service_id + '_public'
            or component.plan.health.path != '/ping'
            or component.plan.health.port != port
            or len(component.plan.network.listeners) != 1
            or (
                component.plan.network.listeners[0].protocol,
                component.plan.network.listeners[0].port,
                component.plan.network.listeners[0].purpose,
            )
            != ('tcp', port, 'web')
        ):
            raise ValueError()
        state = observed.get('State')
        if (
            type(state) is not dict
            or state.get('Status') != 'running'
            or state.get('Running') is not True
            or any(state.get(k) is True for k in ('Paused', 'Restarting', 'Dead'))
        ):
            raise ValueError()
        networks = (observed.get('NetworkSettings') or {}).get('Networks')
        name = body['HostConfig']['NetworkMode']
        if type(networks) is not dict or set(networks) != {name}:
            raise ValueError()
        attached = networks[name]
        prefix = attached.get('IPPrefixLen')
        if (
            type(attached) is not dict
            or attached.get('NetworkID') != binding.network_id
            or type(prefix) is not int
            or not 8 <= prefix <= 30
        ):
            raise ValueError()
        address = _address(attached.get('IPAddress'))
        network = ipaddress.ip_network(f'{address}/{prefix}', strict=False)
        gateway_value = attached.get('Gateway')
        if type(gateway_value) is not str or len(gateway_value) > 15:
            raise ValueError()
        if gateway_value:
            gateway = _address(gateway_value)
            if gateway not in network or gateway in {
                address,
                network.network_address,
                network.broadcast_address,
            }:
                raise ValueError()
        proof = ArrEndpointProof(
            service_id,
            expected_container_id,
            binding.network_id,
            str(address),
            port,
            selected.planHash,
        )
        if type(proof) is not ArrEndpointProof or set(vars(proof)) != {
            f.name for f in fields(ArrEndpointProof)
        }:
            raise ValueError()
        return proof
    except (
        ValueError,
        TypeError,
        AttributeError,
        KeyError,
        StopIteration,
        json.JSONDecodeError,
        ipaddress.AddressValueError,
        ArrEndpointError,
    ):
        raise ArrEndpointError() from None


def open_arr_endpoint(
    observed, binding, stack, expected_container_id, service_id, *, timeout=5.0
):
    if (
        type(timeout) not in (int, float)
        or not math.isfinite(timeout)
        or not 0 < timeout <= 10
    ):
        raise ArrEndpointError('invalid_arr_endpoint_limits')
    proof = prove_arr_endpoint(
        observed, binding, stack, expected_container_id, service_id
    )
    connection = None
    try:
        connection = socket.socket(
            socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP
        )
        connection.settimeout(float(timeout))
        connection.connect((proof.address, proof.port))
        return OpenArrEndpoint(connection, proof)
    except (OSError, RuntimeError, TypeError, ValueError):
        if connection is not None:
            try:
                connection.close()
            except OSError:
                pass
        raise ArrEndpointError('arr_endpoint_unavailable') from None
