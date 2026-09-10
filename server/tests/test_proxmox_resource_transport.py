"""Synthetic loopback PVE API; no physical Proxmox is contacted."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from types import MappingProxyType
from urllib.parse import parse_qs

import pytest

from larenor_server.errors import ApiError
from larenor_server.proxmox.transport import read_summary
from larenor_server.services.probe import ServiceConnection


@pytest.fixture
def pve():
    class Fixture:
        calls = []
        status = 200
        values = [
            {'type': 'node', 'node': 'pve-a', 'status': 'online', 'cpu': .25,
             'mem': 1024, 'maxmem': 4096, 'uptime': 3600},
            {'type': 'qemu', 'vmid': 101, 'node': 'pve-a', 'name': 'media',
             'status': 'running', 'cpu': .5, 'mem': 2048, 'maxmem': 8192},
            {'type': 'lxc', 'vmid': 102, 'node': 'pve-a', 'name': 'dns',
             'status': 'stopped', 'cpu': 0, 'mem': 128, 'maxmem': 512},
            {'type': 'storage', 'storage': 'local-lvm', 'node': 'pve-a',
             'plugintype': 'lvmthin', 'status': 'available', 'disk': 10, 'maxdisk': 100},
        ]
        allow_password = False
    fixture = Fixture()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            fixture.calls.append((self.command, self.path, self.headers.get('Authorization')))
            body = json.dumps({'data': fixture.values}).encode()
            self.send_response(fixture.status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers(); self.wfile.write(body)

        def do_POST(self):
            assert fixture.allow_password and self.path == '/api2/json/access/ticket'
            body = self.rfile.read(int(self.headers['Content-Length'])).decode('ascii')
            assert parse_qs(body) == {'username': ['reader@pam'], 'password': ['synthetic only']}
            fixture.calls.append((self.command, self.path, self.headers.get('Authorization')))
            payload = json.dumps({'data': {'username': 'reader@pam', 'NeedTFA': 0,
                'ticket': 'PVE:reader@pam:fixture-ticket'}}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers(); self.wfile.write(payload)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = Thread(target=server.serve_forever, daemon=True); thread.start()
    fixture.url = f'http://127.0.0.1:{server.server_port}'
    try:
        yield fixture
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=2)


def connection(pve):
    return ServiceConnection(id='a' * 32, revision=7, name='Fixture', kind='proxmox',
        base_url=pve.url, credentials=MappingProxyType({
            'token': 'root@pam!larenor=01234567-89ab-cdef-0123-456789abcdef'}))


def test_packaged_transport_uses_one_fixed_read_and_returns_only_typed_summary(pve):
    result = read_summary(connection(pve), guard=lambda: None)
    assert result.model_dump() == {
        'nodes': [{'node': 'pve-a', 'status': 'online', 'cpuRatio': .25,
                   'memoryUsedBytes': 1024, 'memoryTotalBytes': 4096, 'uptimeSeconds': 3600}],
        'guests': [
            {'vmId': 101, 'node': 'pve-a', 'kind': 'qemu', 'name': 'media',
             'status': 'running', 'cpuRatio': .5, 'memoryUsedBytes': 2048, 'memoryTotalBytes': 8192},
            {'vmId': 102, 'node': 'pve-a', 'kind': 'lxc', 'name': 'dns',
             'status': 'stopped', 'cpuRatio': 0, 'memoryUsedBytes': 128, 'memoryTotalBytes': 512}],
        'storages': [{'storage': 'local-lvm', 'node': 'pve-a', 'kind': 'lvmthin',
                      'active': True, 'usedBytes': 10, 'totalBytes': 100, 'availableBytes': 90}],
    }
    assert pve.calls == [('GET', '/api2/json/cluster/resources',
                          'PVEAPIToken=root@pam!larenor=01234567-89ab-cdef-0123-456789abcdef')]


def test_password_account_uses_ticket_only_then_same_fixed_read(pve):
    pve.allow_password = True
    service = ServiceConnection(id='b' * 32, revision=1, name='Fixture', kind='proxmox',
        base_url=pve.url, credentials=MappingProxyType({
            'username': 'reader@pam', 'password': 'synthetic only'}))
    assert read_summary(service, guard=lambda: None).nodes[0].node == 'pve-a'
    assert [(call[0], call[1]) for call in pve.calls] == [
        ('POST', '/api2/json/access/ticket'), ('GET', '/api2/json/cluster/resources')]


@pytest.mark.parametrize('change', [
    lambda values: values + [{'type': 'pool'}],
    lambda values: [{**values[0], 'status': 'unknown'}, *values[1:]],
    lambda values: [{**values[0], 'cpu': float('nan')}, *values[1:]],
    lambda values: [*values, dict(values[0])],
    lambda values: [*values[:-1], {**values[-1], 'status': 'unknown'}],
])
def test_unknown_unbounded_or_duplicate_provider_data_fails_closed(pve, change):
    pve.values = change(pve.values)
    with pytest.raises(ApiError) as error:
        read_summary(connection(pve), guard=lambda: None)
    assert (error.value.code, error.value.status) == ('proxmox_summary_unsupported', 502)


def test_guard_cancellation_prevents_any_network_request(pve):
    def cancelled():
        raise ApiError('request_timeout', 408)

    with pytest.raises(ApiError) as error:
        read_summary(connection(pve), guard=cancelled)
    assert (error.value.code, error.value.status) == ('request_timeout', 408)
    assert pve.calls == []
