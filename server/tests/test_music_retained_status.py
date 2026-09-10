"""Secret-free retained Music Assistant inventory and readiness projection."""

import json

import pytest
from pydantic import ValidationError

from conftest import auth, bootstrap_password, login, ready
from larenor_server.plugins.music_assistant_core_models import (
    AuthenticatedMusicAssistantReadback,
)
from larenor_server.plugins.music_provider_setup_models import (
    ProviderSetupDiscovery, ProviderSetupWorkerResult,
)
from test_music_assistant_core_wiring import authenticated_peer, installed
from test_admin import activate, create
from test_media_installations_api import ExecutionBackend, prepared


BASE = '/api/v1/admin/media/music-assistant/retained'


class _ProviderWorker:
    def execute_music_provider_setup(self, _action, *, deadline, gate):
        assert gate() is True
        return ProviderSetupWorkerResult(
            state='ready', providerDomain='spotify',
            providerInstanceId='spotify--fixture')


def _ready(server):
    app, client, _, _ = server
    pair, installation_id, installation_revision = installed(server)
    ha = authenticated_peer(server, pair, 'home_assistant')
    jellyfin = authenticated_peer(server, pair, 'jellyfin')
    app.state.core.music_assistant_core.record_authenticated_readback(
        installation_id, installation_revision,
        AuthenticatedMusicAssistantReadback(
            token='private-mass-token', serverId='mass-fixture',
            serverVersion='2.10.2', schemaVersion=27))
    return pair, installation_id, installation_revision, ha, jellyfin


def test_retained_inventory_is_unknown_without_installation(server):
    _app, client, _, _ = server
    pair = ready(server)
    empty = client.get(BASE, headers=auth(pair))
    assert empty.status_code == 200
    assert empty.json() == {
        'schemaVersion': 1, 'state': 'unknown',
        'installAvailable': False, 'installations': []}


def test_retained_inventory_projects_exact_ready_bootstrap_as_partial_without_provider(server):
    _app, client, _, _ = server
    pair, installation_id, revision, ha, jellyfin = _ready(server)
    response = client.get(BASE, headers=auth(pair))
    assert response.status_code == 200
    document = response.json()
    assert document['state'] == 'partial'
    assert document['installAvailable'] is False
    assert document['installations'] == [{
        'installationId': installation_id,
        'installationRevision': revision,
        'installationState': 'container_started',
        'state': 'partial',
        'errorCode': 'provider_not_ready',
        'bootstrapReceipt': {
            'revision': 1, 'state': 'ready', 'serverVersion': '2.10.2',
            'schemaVersion': 27,
            'homeAssistant': {
                'serviceId': ha['id'], 'serviceRevision': ha['revision']},
            'jellyfin': {
                'serviceId': jellyfin['id'],
                'serviceRevision': jellyfin['revision']},
        },
        'providers': [],
    }]
    encoded = json.dumps(document)
    assert 'private-mass-token' not in encoded
    assert 'baseUrl' not in encoded and 'credential' not in encoded


def test_retained_inventory_marks_stale_service_revision_failed(server):
    app, client, _, _ = server
    pair, installation_id, _, ha, _ = _ready(server)
    changed = client.patch(
        '/api/v1/admin/services/' + ha['id'], headers=auth(pair), json={
            'expectedRevision': ha['revision'], 'name': 'Changed HA',
            'baseUrl': ha['baseUrl']})
    assert changed.status_code == 200
    record = client.get(BASE, headers=auth(pair)).json()['installations'][0]
    assert record['installationId'] == installation_id
    assert record['state'] == 'failed'
    assert record['errorCode'] == 'dependency_changed'
    assert record['bootstrapReceipt']['state'] == 'failed'


def test_retained_inventory_is_ready_only_after_exact_provider_readback(server):
    app, client, _, _ = server
    pair, installation_id, revision, _, _ = _ready(server)
    created = client.post(
        '/api/v1/admin/media/music-assistant/providers', headers=auth(pair),
        json={'requestId': 'a' * 32, 'installationId': installation_id,
              'expectedInstallationRevision': revision,
              'providerDomain': 'spotify'}).json()['setup']
    discovered = app.state.core.music_provider_setups.record_initial_discovery(
        created['id'], created['revision'], ProviderSetupDiscovery(
            providerDomain='spotify', flowId='private-flow',
            stepId='authenticate', kind='external',
            externalUrl='https://accounts.spotify.com/authorize?state=private',
            expiresAt=1788610200, entries=[]))
    app.state.core.music_provider_setups.backend = _ProviderWorker()
    completed = client.post(
        f'/api/v1/admin/media/music-assistant/providers/{created["id"]}/resume',
        headers=auth(pair), json={'expectedRevision': discovered['revision']})
    assert completed.status_code == 200
    document = client.get(BASE, headers=auth(pair)).json()
    assert document['state'] == 'ready'
    record = document['installations'][0]
    assert record['state'] == 'ready' and record['errorCode'] is None
    assert record['providers'] == [{
        'id': created['id'], 'providerDomain': 'spotify',
        'revision': completed.json()['setup']['revision'], 'state': 'ready',
        'updatedAt': completed.json()['setup']['updatedAt']}]


def test_retained_inventory_auth_lifecycle_is_admin_only(server):
    _app, client, settings, _ = server
    changing = login(client, 'admin', bootstrap_password(settings)).json()
    denied = client.get(BASE, headers=auth(changing))
    assert denied.status_code == 403
    assert denied.json()['error']['code'] == 'password_change_required'

    admin = ready(server)
    create(client, admin, 'retained-reader')
    member = activate(client, 'retained-reader')
    denied = client.get(BASE, headers=auth(member))
    assert denied.status_code == 403
    assert denied.json()['error']['code'] == 'forbidden'

    assert client.post('/api/v1/auth/logout', headers=auth(admin)).status_code == 204
    assert client.get(BASE, headers=auth(admin)).status_code == 401


def test_queued_installation_is_partial_without_claiming_readiness(server):
    app, client, _, _ = server
    pair, _, _, body = prepared(server)
    app.state.core.media_installations.backend = ExecutionBackend()
    queued = client.post(
        '/api/v1/admin/media/installations', headers=auth(pair),
        json={**body, 'serviceId': 'music_assistant'}).json()['installation']
    record = client.get(BASE, headers=auth(pair)).json()['installations'][0]
    assert record['installationId'] == queued['id']
    assert (record['installationState'], record['state'], record['errorCode']) == (
        'queued', 'partial', 'installation_pending')
    assert record['bootstrapReceipt'] is None


@pytest.mark.parametrize('state', ['failed', 'cancelled', 'needs_attention'])
def test_terminal_installation_failure_states_fail_closed(server, state):
    app, client, _, _ = server
    pair, installation_id, _, _, _ = _ready(server)
    with app.state.core.db.transaction() as connection:
        row = connection.execute(
            'SELECT * FROM media_installations WHERE id=?',
            (installation_id,)).fetchone()
        payload = app.state.core.media_installations._decode(row)
        app.state.core.media_installations._transition(
            connection, row, payload, state=state,
            error='worker_unavailable' if state != 'cancelled' else None,
            cancel=state == 'cancelled')
    record = client.get(BASE, headers=auth(pair)).json()['installations'][0]
    assert (record['installationState'], record['state'], record['errorCode']) == (
        state, 'failed', 'installation_failed')
    assert record['bootstrapReceipt'] is None


@pytest.mark.parametrize('provider_state', ['cancelled', 'needs_attention'])
def test_failed_provider_state_is_visible_without_private_flow_data(
        server, provider_state):
    app, client, _, _ = server
    pair, installation_id, revision, _, _ = _ready(server)
    created = client.post(
        '/api/v1/admin/media/music-assistant/providers', headers=auth(pair),
        json={'requestId': 'b' * 32, 'installationId': installation_id,
              'expectedInstallationRevision': revision,
              'providerDomain': 'spotify'}).json()['setup']
    with app.state.core.db.transaction() as connection:
        current = connection.execute(
            'SELECT * FROM music_provider_setups WHERE id=?',
            (created['id'],)).fetchone()
        stored = app.state.core.music_provider_setups._decode(current)
        changed = dict(current)
        changed.update(revision=current['revision'] + 1,
                       updated_at=current['updated_at'] + 1)
        app.state.core.music_provider_setups._save(
            connection, changed, stored.model_copy(update={'status': provider_state}))
    response = client.get(BASE, headers=auth(pair))
    assert response.status_code == 200
    record = response.json()['installations'][0]
    assert (record['state'], record['errorCode']) == ('failed', 'provider_failed')
    assert record['providers'][0]['state'] == provider_state
    assert 'flowId' not in response.text and 'credential' not in response.text


def test_provider_from_stale_installation_revision_is_not_projected(server):
    app, client, _, _ = server
    pair, installation_id, revision, _, _ = _ready(server)
    created = client.post(
        '/api/v1/admin/media/music-assistant/providers', headers=auth(pair),
        json={'requestId': 'c' * 32, 'installationId': installation_id,
              'expectedInstallationRevision': revision,
              'providerDomain': 'spotify'}).json()['setup']
    with app.state.core.db.transaction() as connection:
        row = connection.execute(
            'SELECT * FROM media_installations WHERE id=?',
            (installation_id,)).fetchone()
        payload = app.state.core.media_installations._decode(row)
        app.state.core.media_installations._transition(
            connection, row, payload, state='container_started')
    record = client.get(BASE, headers=auth(pair)).json()['installations'][0]
    assert created['id'] not in {item['id'] for item in record['providers']}


def test_retained_contract_bounds_installations_and_providers():
    from larenor_server.plugins.music_retained_status_models import (
        MusicRetainedStatusResponse,
    )

    installation = {
        'installationId': '0' * 32, 'installationRevision': 1,
        'installationState': 'queued', 'state': 'partial',
        'errorCode': 'installation_pending', 'bootstrapReceipt': None,
        'providers': [],
    }
    with pytest.raises(ValidationError):
        MusicRetainedStatusResponse.model_validate({
            'schemaVersion': 1, 'state': 'partial', 'installAvailable': False,
            'installations': [installation | {'installationId': f'{i:032x}'}
                              for i in range(65)],
        })
    providers = [{
        'id': f'{i:032x}', 'providerDomain': 'spotify', 'revision': 1,
        'state': 'queued', 'updatedAt': '2026-09-11T00:00:00.000Z',
    } for i in range(257)]
    with pytest.raises(ValidationError):
        MusicRetainedStatusResponse.model_validate({
            'schemaVersion': 1, 'state': 'partial', 'installAvailable': False,
            'installations': [installation | {
                'installationId': 'f' * 32, 'providers': providers}],
        })


def test_corrupt_encrypted_installation_record_fails_closed(server):
    app, client, _, _ = server
    pair, installation_id, _, _, _ = _ready(server)
    with app.state.core.db.transaction() as connection:
        connection.execute(
            'UPDATE media_installations SET ciphertext=? WHERE id=?',
            (b'broken', installation_id))
    response = client.get(BASE, headers=auth(pair))
    assert response.status_code == 503
    assert response.json()['error']['code'] == 'server_unavailable'
    assert 'private-mass-token' not in response.text
