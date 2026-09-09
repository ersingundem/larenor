"""Exact managed-container endpoint proof before Jellyfin bootstrap."""

from dataclasses import replace
import copy
import inspect
import socket

import pytest

from larenor_server.plugins.jellyfin_endpoint import (
    JellyfinEndpointError, open_jellyfin_endpoint, prove_jellyfin_endpoint,
)
from test_managed_container_binding import build, snapshot


def running():
    _builder, stack, binding = build()
    value = snapshot(binding)
    value['State'] = {'Status': 'running', 'Running': True, 'Paused': False,
                      'Restarting': False, 'Dead': False}
    attached = next(iter(value['NetworkSettings']['Networks'].values()))
    attached.update({'IPAddress': '172.28.0.2', 'IPPrefixLen': 16,
                     'Gateway': '172.28.0.1'})
    return stack, binding, value


def test_running_exact_container_yields_private_fixed_jellyfin_endpoint():
    stack, binding, observed = running()
    proof = prove_jellyfin_endpoint(observed, binding, stack, '5' * 64)
    assert (proof.container_id, proof.network_id, proof.address, proof.port,
            proof.plan_hash) == (
        '5' * 64, binding.network_id, '172.28.0.2', 8096, stack.planHash,
    )
    assert '172.28.0.2' not in repr(proof)


def test_internal_network_without_default_route_keeps_private_endpoint_valid():
    stack, binding, observed = running()
    attached = next(iter(observed['NetworkSettings']['Networks'].values()))
    attached['Gateway'] = ''

    proof = prove_jellyfin_endpoint(observed, binding, stack, '5' * 64)

    assert proof.address == '172.28.0.2'
    assert proof.network_id == binding.network_id


@pytest.mark.parametrize('damage', [
    'container', 'binding', 'stopped', 'paused', 'restarting', 'dead',
    'network', 'missing_ip', 'public_ip', 'loopback', 'link_local',
    'prefix_bool', 'prefix_wide', 'gateway_missing', 'gateway_public', 'gateway_outside',
    'plan', 'extra_network',
])
def test_drift_or_nonprivate_endpoint_never_becomes_connection_authority(damage, monkeypatch):
    stack, binding, observed = running()
    if damage == 'container':
        observed['Id'] = '6' * 64
    elif damage == 'binding':
        binding = replace(binding, network_id='9' * 64)
    elif damage in {'stopped', 'paused', 'restarting', 'dead'}:
        if damage == 'stopped':
            observed['State'].update(Status='exited', Running=False)
        else:
            observed['State'][damage.capitalize()] = True
    elif damage == 'network':
        next(iter(observed['NetworkSettings']['Networks'].values()))['NetworkID'] = '9' * 64
    elif damage == 'extra_network':
        observed['NetworkSettings']['Networks']['foreign'] = copy.deepcopy(
            next(iter(observed['NetworkSettings']['Networks'].values())))
    elif damage == 'plan':
        object.__setattr__(stack, 'planHash', '9' * 64)
    else:
        attached = next(iter(observed['NetworkSettings']['Networks'].values()))
        changes = {
            'missing_ip': {'IPAddress': ''}, 'public_ip': {'IPAddress': '8.8.8.8'},
            'loopback': {'IPAddress': '127.0.0.1'}, 'link_local': {'IPAddress': '169.254.1.2'},
            'prefix_bool': {'IPPrefixLen': True}, 'prefix_wide': {'IPPrefixLen': 7},
            'gateway_missing': {'Gateway': None},
            'gateway_public': {'Gateway': '8.8.8.8'},
            'gateway_outside': {'Gateway': '172.29.0.1'},
        }
        attached.update(changes[damage])
    monkeypatch.setattr(socket, 'socket', lambda *_a, **_k: (_ for _ in ()).throw(
        AssertionError('invalid proof must not open a socket')))
    with pytest.raises(JellyfinEndpointError, match='^jellyfin_endpoint_untrusted$'):
        open_jellyfin_endpoint(observed, binding, stack, '5' * 64)


class Connection:
    def __init__(self, fail=False):
        self.fail = fail
        self.calls = []
        self.closed = False

    def settimeout(self, value):
        self.calls.append(('timeout', value))

    def connect(self, address):
        self.calls.append(('connect', address))
        if self.fail:
            raise OSError('private target must not escape')

    def close(self):
        self.closed = True


def test_connector_uses_one_numeric_ipv4_target_without_dns_or_retry(monkeypatch):
    stack, binding, observed = running()
    connection = Connection()
    calls = []
    monkeypatch.setattr(socket, 'getaddrinfo', lambda *_a, **_k: (_ for _ in ()).throw(
        AssertionError('numeric managed endpoint must not use DNS')))
    monkeypatch.setattr(socket, 'socket', lambda family, kind, protocol: calls.append(
        (family, kind, protocol)) or connection)

    opened = open_jellyfin_endpoint(observed, binding, stack, '5' * 64, timeout=3.0)

    assert opened.connection is connection and opened.proof.address == '172.28.0.2'
    assert calls == [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP)]
    assert connection.calls[-1] == ('connect', ('172.28.0.2', 8096))
    assert len([item for item in connection.calls if item[0] == 'connect']) == 1
    assert not connection.closed and '172.28.0.2' not in repr(opened)


def test_connect_failure_closes_once_and_returns_only_a_static_code(monkeypatch):
    stack, binding, observed = running()
    connection = Connection(fail=True)
    monkeypatch.setattr(socket, 'socket', lambda *_a: connection)
    with pytest.raises(JellyfinEndpointError, match='^jellyfin_endpoint_unavailable$') as raised:
        open_jellyfin_endpoint(observed, binding, stack, '5' * 64)
    assert connection.closed and len([item for item in connection.calls if item[0] == 'connect']) == 1
    assert '172.28.0.2' not in str(raised.value) + repr(raised.value)


@pytest.mark.parametrize('timeout', [True, 0, -1, 10.1, float('inf'), '5'])
def test_timeout_is_packaged_and_invalid_values_open_no_socket(timeout, monkeypatch):
    stack, binding, observed = running()
    monkeypatch.setattr(socket, 'socket', lambda *_a: (_ for _ in ()).throw(
        AssertionError('invalid limit must not open a socket')))
    with pytest.raises(JellyfinEndpointError, match='^invalid_jellyfin_endpoint_limits$'):
        open_jellyfin_endpoint(observed, binding, stack, '5' * 64, timeout=timeout)


def test_closed_surface_has_no_client_selected_target_or_transport_hooks():
    parameters = inspect.signature(open_jellyfin_endpoint).parameters
    assert set(parameters) == {'observed', 'binding', 'stack', 'expected_container_id', 'timeout'}
    assert not {'url', 'host', 'port', 'address', 'resolver', 'connector', 'proxy'} & set(parameters)
