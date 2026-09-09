"""HTTP and durability contract for the first closed S06.4 execution slice."""

from fastapi.testclient import TestClient
import pytest

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.plugins.preflight_models import PreflightResult
from larenor_server.plugins.worker import StepReceipt
from test_media_inspections import Backend as InspectionBackend
from test_media_preparations_api import create_preparation


BASE = '/api/v1/admin/media/installations'


class ExecutionBackend:
    def __init__(self, change=None):
        self.calls = []
        self.change = change

    def apply(self, step, component):
        self.calls.append(('apply', step.kind, component.serviceId))
        if self.change:
            action, self.change = self.change, None
            action()
        code = 'container_created' if step.kind == 'create_container' else 'container_started'
        return StepReceipt(step.job_id, step.kind, 'succeeded', code, '1' * 64)

    def reconcile(self, step, component):
        self.calls.append(('reconcile', step.kind, component.serviceId))
        return StepReceipt(step.job_id, step.kind, 'succeeded', 'container_created', '1' * 64)


def prepared(server):
    app, client, _, _ = server
    pair = ready(server)
    _, preparation = create_preparation(client, pair)
    inspector = InspectionBackend()
    inspector.action = lambda plan: PreflightResult.model_validate({
        'catalogDigest': plan.catalogDigest, 'planHash': plan.planHash,
        'platform': plan.platform, 'checkedAt': '2026-09-05T12:00:00.000Z',
        'checks': [
            {'code': 'platform', 'status': 'passed'},
            {'code': 'docker_engine', 'status': 'passed'},
            {'code': 'storage_root', 'status': 'passed', 'rootId': 'appdata'},
            {'code': 'storage_capacity', 'status': 'passed', 'rootId': 'appdata',
             'availableMiB': 65536, 'requiredMiB': 49152},
            {'code': 'daemon_mount_context', 'status': 'passed'},
            {'code': 'daemon_network_context', 'status': 'passed'},
            {'code': 'daemon_root_context', 'status': 'passed'},
        ],
    })
    app.state.core.media_inspections.backend = inspector
    response = client.post('/api/v1/admin/media/inspections', headers=auth(pair), json={
        'requestId': 'b' * 32, 'preparationId': preparation['id'], 'expectedRevision': 1,
        'planHash': preparation['plan']['planHash']})
    assert response.status_code == 201
    inspection = response.json()['inspection']
    inspection = app.state.core.media_inspections.tick()['inspection']
    assert inspection['state'] == 'succeeded'
    body = {'requestId': 'c' * 32, 'preparationId': preparation['id'],
            'inspectionId': inspection['id'], 'expectedPreparationRevision': 1,
            'expectedInspectionRevision': inspection['revision'],
            'planHash': preparation['plan']['planHash']}
    return pair, preparation, inspection, body


def test_admin_can_queue_closed_jellyfin_execution_and_read_it_after_restart(server):
    app, client, settings, _ = server
    pair, _, _, body = prepared(server)
    app.state.core.media_installations.backend = ExecutionBackend()
    assert client.get(BASE + '/capabilities', headers=auth(pair)).json() == {
        'executionConfigured': True, 'installAvailable': False, 'services': ['jellyfin']}
    response = client.post(BASE, headers=auth(pair), json=body)
    assert response.status_code == 201
    record = response.json()['installation']
    assert record['state'] == record['phase'] == 'queued'
    assert record['serviceId'] == 'jellyfin' and record['installAvailable'] is False
    assert set(record['steps'][0]) == {'stepId', 'kind'}
    assert 'Image' not in response.text and 'HostConfig' not in response.text
    assert client.post(BASE, headers=auth(pair), json=body).json() == {'installation': record}
    with TestClient(create_app(settings)) as reopened:
        assert reopened.get(BASE + '/' + record['id'], headers=auth(pair)).json() == {'installation': record}


def test_second_request_for_the_same_preparation_is_an_explicit_conflict(server):
    app, client, _, _ = server
    pair, _, _, body = prepared(server)
    app.state.core.media_installations.backend = ExecutionBackend()
    first = client.post(BASE, headers=auth(pair), json=body)
    assert first.status_code == 201

    response = client.post(BASE, headers=auth(pair),
                           json=body | {'requestId': 'd' * 32})
    assert response.status_code == 409
    assert response.json()['error']['code'] == 'media_installation_conflict'


def test_tick_rechecks_authority_between_create_and_start(server):
    app, client, _, _ = server
    pair, _, _, body = prepared(server)
    backend = ExecutionBackend(lambda: client.post('/api/v1/auth/logout', headers=auth(pair)))
    app.state.core.media_installations.backend = backend
    record = client.post(BASE, headers=auth(pair), json=body).json()['installation']
    terminal = app.state.core.media_installations.tick()['installation']
    assert terminal['state'] == 'needs_attention' and terminal['errorCode'] == 'authority_changed'
    assert terminal['phase'] == 'complete'
    assert backend.calls == [('apply', 'create_container', 'jellyfin')]
    assert terminal['id'] == record['id']


def test_success_means_container_phase_only_and_keeps_product_install_disabled(server):
    app, client, _, _ = server
    pair, _, _, body = prepared(server)
    backend = ExecutionBackend()
    app.state.core.media_installations.backend = backend
    record = client.post(BASE, headers=auth(pair), json=body).json()['installation']
    terminal = app.state.core.media_installations.tick()['installation']
    assert terminal['state'] == 'container_started' and terminal['phase'] == 'complete'
    assert terminal['installAvailable'] is False and terminal['errorCode'] is None
    assert backend.calls == [('apply', 'create_container', 'jellyfin'),
                             ('apply', 'start_container', 'jellyfin')]
    assert client.get(BASE + '/' + record['id'], headers=auth(pair)).json()['installation'] == terminal


@pytest.mark.parametrize('extra', [
    {'docker': {'Privileged': True}}, {'serviceId': 'sonarr'},
    {'command': 'docker run'}, {'expectedInspectionRevision': True},
])
def test_http_request_rejects_effect_selection_and_never_echoes_it(server, extra):
    app, client, _, _ = server
    pair, _, _, body = prepared(server)
    app.state.core.media_installations.backend = ExecutionBackend()
    response = client.post(BASE, headers=auth(pair), json=body | extra)
    assert response.status_code == 400 and response.json()['error']['code'] == 'invalid_request'
    assert 'docker run' not in response.text and 'Privileged' not in response.text


def test_unsuccessful_or_changed_inspection_never_queues_an_effect(server):
    app, client, _, _ = server
    pair, preparation, inspection, body = prepared(server)
    app.state.core.media_installations.backend = ExecutionBackend()
    bad = body | {'expectedInspectionRevision': inspection['revision'] - 1}
    response = client.post(BASE, headers=auth(pair), json=bad)
    assert response.status_code == 409
    assert response.json()['error']['code'] == 'media_inspection_changed'
    client.post('/api/v1/admin/media/preparations/' + preparation['id'] + '/cancel',
                headers=auth(pair), json={'expectedRevision': 1})
    response = client.post(BASE, headers=auth(pair), json=body | {'requestId': 'd' * 32})
    assert response.status_code == 409
    assert response.json()['error']['code'] == 'media_preparation_changed'


def test_catalog_change_preserves_history_but_blocks_new_effect(server, monkeypatch):
    app, client, _, _ = server
    pair, _, _, body = prepared(server)
    backend = ExecutionBackend()
    app.state.core.media_installations.backend = backend
    record = client.post(BASE, headers=auth(pair), json=body).json()['installation']
    monkeypatch.setattr('larenor_server.plugins.media_installations.load_catalog',
                        lambda: (_ for _ in ()).throw(ValueError('private catalog path')))
    monkeypatch.setattr('larenor_server.plugins.installation_execution.load_catalog',
                        lambda: (_ for _ in ()).throw(ValueError('private catalog path')))
    assert client.get(BASE + '/' + record['id'], headers=auth(pair)).json() == {'installation': record}
    terminal = app.state.core.media_installations.tick()['installation']
    assert terminal['state'] == 'needs_attention' and terminal['errorCode'] == 'catalog_changed'
    assert backend.calls == [] and 'private catalog path' not in repr(terminal)


def test_cancelled_queue_and_encrypted_payload_never_reach_worker(server):
    app, client, _, _ = server
    pair, _, _, body = prepared(server)
    backend = ExecutionBackend()
    app.state.core.media_installations.backend = backend
    record = client.post(BASE, headers=auth(pair), json=body).json()['installation']
    with app.state.core.db.connection() as connection:
        row = connection.execute('SELECT nonce,ciphertext FROM media_installations').fetchone()
        assert len(row['nonce']) == 12 and body['planHash'].encode() not in row['ciphertext']
    cancelled = client.post(BASE + '/' + record['id'] + '/cancel', headers=auth(pair),
                            json={'expectedRevision': 1}).json()['installation']
    assert cancelled['state'] == 'cancelled' and cancelled['cancelRequested']
    assert app.state.core.media_installations.tick() is None and backend.calls == []
