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
        resources = [
            {'type': 'node', 'node': 'pve-a', 'status': 'online', 'cpu': .25,
             'mem': 1024, 'maxmem': 4096, 'uptime': 3600},
            {'type': 'qemu', 'vmid': 101, 'node': 'pve-a', 'name': 'media',
             'status': 'running', 'cpu': .5, 'mem': 2048, 'maxmem': 8192},
            {'type': 'lxc', 'vmid': 102, 'node': 'pve-a', 'name': 'dns',
             'status': 'stopped', 'cpu': 0, 'mem': 128, 'maxmem': 512},
            {'type': 'storage', 'storage': 'local-lvm', 'node': 'pve-a',
             'plugintype': 'lvmthin', 'status': 'available', 'disk': 10, 'maxdisk': 100},
        ]
        tasks = [{
            'upid': 'UPID:pve-a:00001234:00005678:66E2B900:vzdump:101:root@pam:',
            'node': 'pve-a', 'type': 'vzdump', 'starttime': 1789113600,
            'endtime': 1789113780, 'status': 'OK', 'user': 'root@pam',
        }]
        allow_password = False
    fixture = Fixture()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            fixture.calls.append((self.command, self.path, self.headers.get('Authorization')))
            values = fixture.tasks if self.path == '/api2/json/cluster/tasks?limit=20' else fixture.resources
            body = json.dumps({'data': values}).encode()
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
        'recentTasks': [{
            'taskId': 'b926f4455b95b320c913eed90f49f6127788f638b43070cada843afe490c9628',
            'node': 'pve-a', 'kind': 'vzdump', 'status': 'succeeded',
            'startedAt': '2026-09-11T08:00:00Z',
            'finishedAt': '2026-09-11T08:03:00Z',
        }],
        'maintenance': {
            'state': 'healthy', 'warningCount': 0, 'truncated': False,
            'warnings': [],
        },
    }
    assert pve.calls == [
        ('GET', '/api2/json/cluster/resources',
         'PVEAPIToken=root@pam!larenor=01234567-89ab-cdef-0123-456789abcdef'),
        ('GET', '/api2/json/cluster/tasks?limit=20',
         'PVEAPIToken=root@pam!larenor=01234567-89ab-cdef-0123-456789abcdef'),
    ]
    assert 'root@pam' not in json.dumps(result.model_dump())


def test_password_account_uses_ticket_only_then_same_fixed_read(pve):
    pve.allow_password = True
    service = ServiceConnection(id='b' * 32, revision=1, name='Fixture', kind='proxmox',
        base_url=pve.url, credentials=MappingProxyType({
            'username': 'reader@pam', 'password': 'synthetic only'}))
    assert read_summary(service, guard=lambda: None).nodes[0].node == 'pve-a'
    assert [(call[0], call[1]) for call in pve.calls] == [
        ('POST', '/api2/json/access/ticket'), ('GET', '/api2/json/cluster/resources'),
        ('GET', '/api2/json/cluster/tasks?limit=20')]


@pytest.mark.parametrize('change', [
    lambda values: values + [{'type': 'pool'}],
    lambda values: [{**values[0], 'status': 'unknown'}, *values[1:]],
    lambda values: [{**values[0], 'cpu': float('nan')}, *values[1:]],
    lambda values: [*values, dict(values[0])],
    lambda values: [*values[:-1], {**values[-1], 'status': 'unknown'}],
])
def test_unknown_unbounded_or_duplicate_provider_data_fails_closed(pve, change):
    pve.resources = change(pve.resources)
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


@pytest.mark.parametrize('change', [
    lambda values: values * 21,
    lambda values: [{**values[0], 'status': None, 'endtime': 1789113780}],
    lambda values: [{**values[0], 'status': 'OK', 'endtime': None}],
    lambda values: [{**values[0], 'starttime': -1}],
    lambda values: [{**values[0], 'type': 'vzdump\nroot@pam'}],
])
def test_task_projection_is_bounded_and_fails_closed(pve, change):
    pve.tasks = change(pve.tasks)
    with pytest.raises(ApiError) as error:
        read_summary(connection(pve), guard=lambda: None)
    assert (error.value.code, error.value.status) == ('proxmox_summary_unsupported', 502)


def test_capacity_pressure_and_failed_tasks_produce_bounded_redacted_warnings(pve):
    pve.resources[0] = {**pve.resources[0], 'cpu': .95, 'mem': 3900}
    pve.resources[-1] = {**pve.resources[-1], 'disk': 95}
    pve.tasks[0] = {**pve.tasks[0], 'status': 'token=private-error'}
    summary = read_summary(connection(pve), guard=lambda: None).model_dump()
    maintenance = summary['maintenance']
    assert maintenance['state'] == 'critical'
    assert maintenance['warningCount'] == 4 and maintenance['truncated'] is False
    assert [warning['kind'] for warning in maintenance['warnings']] == [
        'node_cpu_pressure', 'node_memory_pressure', 'storage_pressure',
        'recent_task_failed',
    ]
    assert all(set(warning) == {
        'warningId', 'kind', 'severity', 'node', 'storage',
        'observedPercent', 'thresholdPercent', 'relatedTaskId',
    } for warning in maintenance['warnings'])
    assert 'private-error' not in json.dumps(summary)


def test_warning_projection_is_capped_without_hiding_total_pressure(pve):
    pve.resources = [
        {'type': 'node', 'node': f'pve-{index}', 'status': 'online',
         'cpu': .95, 'mem': 95, 'maxmem': 100, 'uptime': 3600}
        for index in range(32)
    ]
    summary = read_summary(connection(pve), guard=lambda: None).maintenance
    assert len(summary.warnings) == 32
    assert summary.warningCount == 64 and summary.truncated is True
