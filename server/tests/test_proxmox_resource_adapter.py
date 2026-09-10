"""Core-authorized Proxmox summary pilot; all upstream data is synthetic."""
from fastapi.testclient import TestClient
import pytest

from conftest import auth, ready
from test_admin import activate, create as create_user
from larenor_server.app import create_app
from larenor_server.errors import ApiError


SUMMARY = {
    'nodes': [{'node': 'pve-a', 'status': 'online', 'cpuRatio': 0.25,
               'memoryUsedBytes': 1024, 'memoryTotalBytes': 4096, 'uptimeSeconds': 3600}],
    'guests': [{'vmId': 101, 'node': 'pve-a', 'kind': 'qemu', 'name': 'media',
                'status': 'running', 'cpuRatio': 0.5, 'memoryUsedBytes': 2048,
                'memoryTotalBytes': 8192}],
    'storages': [{'storage': 'local-lvm', 'node': 'pve-a', 'kind': 'lvmthin',
                  'active': True, 'usedBytes': 10, 'totalBytes': 100,
                  'availableBytes': 90}],
    'recentTasks': [{
        'taskId': '9' * 64, 'node': 'pve-a', 'kind': 'vzdump',
        'status': 'succeeded', 'startedAt': '2026-09-11T08:00:00Z',
        'finishedAt': '2026-09-11T08:03:00Z',
    }],
    'maintenance': {
        'state': 'healthy', 'warningCount': 0, 'truncated': False,
        'warnings': [],
    },
    'protection': {
        'state': 'available', 'guestCount': 1, 'scannedGuestCount': 1,
        'truncated': False,
        'latestBackup': {
            'taskId': '9' * 64, 'node': 'pve-a', 'kind': 'vzdump',
            'status': 'succeeded',
            'startedAt': '2026-09-11T08:00:00Z',
            'finishedAt': '2026-09-11T08:03:00Z',
        },
        'snapshots': [{
            'node': 'pve-a', 'kind': 'qemu', 'vmId': 101,
            'snapshotCount': 2, 'latestAt': '2026-09-11T07:30:00Z',
        }],
    },
}


def setup(server):
    app, client, _, _ = server
    admin = ready(server); scope = app.state.core.context
    resource = client.post(
        f'/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}', headers=auth(admin),
        json={'kind': 'resource', 'label': 'Synthetic cluster', 'order': 0}).json()['record']
    service = client.post('/api/v1/admin/services', headers=auth(admin), json={
        'kind': 'proxmox', 'name': 'Synthetic PVE', 'baseUrl': 'https://pve.invalid:8006',
        'credentials': {'token': 'root@pam!larenor=01234567-89ab-cdef-0123-456789abcdef'},
    }).json()['service']
    suffix = f'/proxmox/{scope.coreId}/{scope.homeId}/resources/{resource["ref"]["id"]}'
    base, public = '/api/v1/admin' + suffix, '/api/v1' + suffix
    body = {'serviceId': service['id'], 'expectedServiceRevision': 1,
            'expectedRevision': 1, 'expectedAclRevision': 1, 'expectedBindingId': None}
    adapter = app.state.core.proxmox
    calls = []

    def reader(connection, *, guard):
        calls.append(connection)
        guard()
        return SUMMARY

    adapter._reader = reader
    return app, client, admin, resource, service, base, public, body, calls


def bind(client, admin, base, body):
    preview = client.post(base + '/binding-preview', headers=auth(admin), json=body)
    assert preview.status_code == 201, preview.text
    value = preview.json()['preview']
    confirmed = client.post(base + '/binding-confirm', headers=auth(admin),
                            json={'previewId': value['id']})
    assert confirmed.status_code == 201, confirmed.text
    return value, confirmed.json()['binding']


def test_admin_preview_confirm_and_acl_authorized_typed_cached_snapshot(server):
    app, client, admin, resource, service, base, public, body, calls = setup(server)
    preview, binding = bind(client, admin, base, body)
    assert binding == preview['binding']
    assert preview['summary'] == SUMMARY
    assert client.post(base + '/binding-confirm', headers=auth(admin),
                       json={'previewId': preview['id']}).status_code == 409
    first = client.get(public + '/snapshot', headers=auth(admin))
    assert first.status_code == 200, first.text
    snapshot = first.json()['snapshot']
    assert snapshot['ref'] == resource['ref']
    assert snapshot['bindingId'] == binding['id']
    assert snapshot['serviceId'] == service['id'] and snapshot['serviceRevision'] == 1
    assert snapshot['summary'] == SUMMARY and 0 < snapshot['remainingTtlMs'] <= 5000
    assert len(calls) == 2
    assert client.get(public + '/snapshot', headers=auth(admin)).status_code == 200
    assert len(calls) == 2
    assert '01234567-89ab' not in first.text and 'pve.invalid' not in first.text

    create_user(client, admin); member = activate(client, 'member')
    assert client.get(public + '/snapshot', headers=auth(member)).status_code == 404
    assert client.post(base + '/binding-preview', headers=auth(member), json=body).status_code == 403
    ref = resource['ref']
    grant = f'/api/v1/admin/home-resources/{ref["coreId"]}/{ref["homeId"]}/{ref["id"]}/grants/{member["user"]["id"]}'
    response = client.put(grant, headers=auth(admin), json={
        'expectedAclRevision': 1, 'permissions': {'read': True, 'write': False}})
    assert response.status_code == 200, response.text
    assert client.get(public + '/snapshot', headers=auth(member)).status_code == 200
    assert len(calls) == 3  # Cache is isolated by the full user/session tuple.


@pytest.mark.parametrize('change', ['service', 'acl', 'session', 'cancel'])
def test_late_summary_cannot_publish_after_authority_or_request_changes(server, change):
    app, client, admin, resource, service, base, public, body, calls = setup(server)
    bind(client, admin, base, body)

    def late(connection, *, guard):
        if change == 'service':
            changed = client.patch('/api/v1/admin/services/' + service['id'], headers=auth(admin), json={
                'expectedRevision': 1, 'name': 'Changed', 'baseUrl': 'https://new.invalid:8006',
                'credentials': {'token': 'root@pam!new=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'}})
            assert changed.status_code == 200
        elif change == 'acl':
            create_user(client, admin)
            member = activate(client, 'member')
            ref = resource['ref']
            target = f'/api/v1/admin/home-resources/{ref["coreId"]}/{ref["homeId"]}/{ref["id"]}/grants/{member["user"]["id"]}'
            assert client.put(target, headers=auth(admin), json={
                'expectedAclRevision': 1, 'permissions': {'read': True, 'write': False}}).status_code == 200
        elif change == 'session':
            with app.state.core.db.transaction() as c:
                c.execute('UPDATE session_families SET revoked_at=? WHERE id=?',
                          (app.state.core.settings.clock(), admin['refreshToken'] and connection_actor_family(app, admin)))
        guard()
        return SUMMARY

    if change == 'cancel':
        app.state.core.proxmox._reader = lambda connection, *, guard: SUMMARY
        with pytest.raises(ApiError) as error:
            app.state.core.proxmox.snapshot(
                app.state.core.auth.authenticate(admin['accessToken']), resource['ref']['coreId'],
                resource['ref']['homeId'], resource['ref']['id'], cancelled=lambda: True)
        assert (error.value.code, error.value.status) == ('request_timeout', 408)
    else:
        app.state.core.proxmox._reader = late
        response = client.get(public + '/snapshot', headers=auth(admin))
        assert response.status_code in ({'service': 409, 'acl': 409, 'session': 401}[change],), response.text


def connection_actor_family(app, pair):
    return app.state.core.auth.authenticate(pair['accessToken']).family_id


def test_preview_cancel_restart_close_clock_rollback_and_unknown_are_fail_closed(server):
    app, client, admin, resource, service, base, public, body, calls = setup(server)
    candidate = client.post(base + '/binding-preview', headers=auth(admin), json=body).json()['preview']
    assert client.delete(base + '/binding-preview/' + candidate['id'], headers=auth(admin)).status_code == 204
    assert client.post(base + '/binding-confirm', headers=auth(admin),
                       json={'previewId': candidate['id']}).status_code == 409
    preview, _ = bind(client, admin, base, body)
    settings = server[2]
    with TestClient(create_app(settings)) as restarted:
        assert restarted.post(base + '/binding-confirm', headers=auth(admin),
                              json={'previewId': preview['id']}).status_code == 409

    adapter = app.state.core.proxmox
    adapter._cache.clear(); adapter._last_clock = None
    now = [10.0]; adapter._clock = lambda: now[0]
    assert client.get(public + '/snapshot', headers=auth(admin)).status_code == 200
    now[0] = 9.0
    rolled = client.get(public + '/snapshot', headers=auth(admin))
    assert rolled.status_code == 503
    adapter._clock = lambda: 11.0; adapter._last_clock = None
    adapter._reader = lambda connection, *, guard: {
        **SUMMARY, 'nodes': [{**SUMMARY['nodes'][0], 'status': 'mystery'}]}
    unknown = client.get(public + '/snapshot', headers=auth(admin))
    assert unknown.status_code == 502
    adapter.close()
    assert client.get(public + '/snapshot', headers=auth(admin)).status_code == 503


def test_binding_requires_exact_proxmox_service_revision_and_cache_is_bounded(server, monkeypatch):
    from larenor_server.proxmox import service as module
    app, client, admin, resource, service, base, public, body, calls = setup(server)
    wrong = {**body, 'expectedServiceRevision': 2}
    assert client.post(base + '/binding-preview', headers=auth(admin), json=wrong).status_code == 409
    bind(client, admin, base, body)
    monkeypatch.setattr(module, 'MAX_CACHE', 1); monkeypatch.setattr(module, 'MAX_USER_CACHE', 1)
    assert client.get(public + '/snapshot', headers=auth(admin)).status_code == 200
    assert len(app.state.core.proxmox._cache) <= 1


@pytest.mark.parametrize('tasks', [
    [*SUMMARY['recentTasks'], dict(SUMMARY['recentTasks'][0])],
    [{**SUMMARY['recentTasks'][0], 'status': 'unknown'}],
    [{**SUMMARY['recentTasks'][0], 'actor': 'root@pam'}],
    [{**SUMMARY['recentTasks'][0], 'finishedAt': None}],
    [dict(SUMMARY['recentTasks'][0]) for _ in range(33)],
])
def test_recent_tasks_are_closed_bounded_and_actor_free(server, tasks):
    app, client, admin, resource, _, base, public, body, _ = setup(server)
    bind(client, admin, base, body)
    app.state.core.proxmox._cache.clear()
    app.state.core.proxmox._reader = lambda connection, *, guard: {
        **SUMMARY, 'recentTasks': tasks,
    }
    response = client.get(public + '/snapshot', headers=auth(admin))
    assert response.status_code == 502, response.text
    assert 'root@pam' not in response.text


@pytest.mark.parametrize('maintenance', [
    {'state': 'healthy', 'warningCount': 1, 'truncated': False, 'warnings': []},
    {'state': 'unknown', 'warningCount': 0, 'truncated': False, 'warnings': []},
    {'state': 'healthy', 'warningCount': 0, 'truncated': False, 'warnings': [],
     'host': 'pve.internal'},
    {'state': 'critical', 'warningCount': 1, 'truncated': False, 'warnings': [{
        'warningId': '8' * 64, 'kind': 'node_cpu_pressure', 'severity': 'critical',
        'node': 'pve-a', 'storage': None, 'observedPercent': 95,
        'thresholdPercent': 90, 'relatedTaskId': None, 'rawError': 'private',
    }]},
])
def test_maintenance_summary_is_strict_and_secret_free(server, maintenance):
    app, client, admin, _, _, base, public, body, _ = setup(server)
    bind(client, admin, base, body)
    app.state.core.proxmox._cache.clear()
    app.state.core.proxmox._reader = lambda connection, *, guard: {
        **SUMMARY, 'maintenance': maintenance,
    }
    response = client.get(public + '/snapshot', headers=auth(admin))
    assert response.status_code == 502, response.text
    assert 'pve.internal' not in response.text and 'private' not in response.text


@pytest.mark.parametrize('protection', [
    {'state': 'unknown', 'guestCount': 1, 'scannedGuestCount': 1,
     'truncated': False, 'latestBackup': None, 'snapshots': []},
    {**SUMMARY['protection'], 'guestCount': 2},
    {**SUMMARY['protection'], 'host': 'pve.internal'},
    {**SUMMARY['protection'], 'latestBackup': {
        **SUMMARY['protection']['latestBackup'], 'taskId': '8' * 64}},
    {**SUMMARY['protection'], 'snapshots': [{
        **SUMMARY['protection']['snapshots'][0], 'vmId': 999}]},
    {**SUMMARY['protection'], 'snapshots': [{
        **SUMMARY['protection']['snapshots'][0], 'description': 'private'}]},
])
def test_backup_snapshot_summary_is_strict_and_secret_free(server, protection):
    app, client, admin, _, _, base, public, body, _ = setup(server)
    bind(client, admin, base, body)
    app.state.core.proxmox._cache.clear()
    app.state.core.proxmox._reader = lambda connection, *, guard: {
        **SUMMARY, 'protection': protection,
    }
    response = client.get(public + '/snapshot', headers=auth(admin))
    assert response.status_code == 502, response.text
    assert 'pve.internal' not in response.text and 'private' not in response.text
