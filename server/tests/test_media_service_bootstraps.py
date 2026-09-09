"""S06.5 private credential intent and public API contract."""

from fastapi.testclient import TestClient
import pytest

from conftest import auth, ready
from larenor_server.app import create_app
from test_media_installations_api import ExecutionBackend, prepared


BASE = '/api/v1/admin/media/bootstraps'
SECRET = 'Synthetic-private-bootstrap-secret-0123456789'


def installed(server):
    app, client, _, _ = server
    pair, _, _, body = prepared(server)
    app.state.core.media_installations.backend = ExecutionBackend()
    installation = client.post('/api/v1/admin/media/installations',
                               headers=auth(pair), json=body).json()['installation']
    terminal = app.state.core.media_installations.tick()['installation']
    assert terminal['id'] == installation['id'] and terminal['state'] == 'container_started'
    return pair, terminal


def request(installation, request_id='d' * 32):
    return {'requestId': request_id, 'installationId': installation['id'],
            'expectedInstallationRevision': installation['revision']}


def test_server_generates_and_encrypts_private_bootstrap_without_network(server, monkeypatch):
    app, client, _, _ = server
    pair, installation = installed(server)
    monkeypatch.setattr('larenor_server.plugins.media_service_bootstraps.secrets.token_urlsafe',
                        lambda size: SECRET)

    response = client.post(BASE, headers=auth(pair), json=request(installation))
    assert response.status_code == 201
    record = response.json()['bootstrap']
    assert record == {
        'id': record['id'], 'requestId': 'd' * 32,
        'installationId': installation['id'], 'serviceId': 'jellyfin',
        'revision': 1, 'state': 'queued', 'credentialsConfigured': False,
        'wiringState': 'pending', 'installAvailable': False,
        'createdAt': '2026-09-05T12:00:00.000Z',
        'updatedAt': '2026-09-05T12:00:00.000Z',
    }
    assert SECRET not in response.text and 'password' not in response.text.lower()
    with app.state.core.db.connection() as connection:
        row = connection.execute('SELECT nonce,ciphertext FROM media_service_bootstraps').fetchone()
        assert len(row['nonce']) == 12
        assert SECRET.encode() not in row['ciphertext']
    private = app.state.core.media_service_bootstraps.private_payload(record['id'])
    assert private.credential == SECRET and private.username == 'larenor-system'
    assert private.locale == 'tr-TR' and private.remote_access is False
    assert not hasattr(app.state.core.media_service_bootstraps, 'transport')


def test_bootstrap_is_idempotent_and_survives_restart_without_secret_exposure(server):
    app, client, settings, _ = server
    pair, installation = installed(server)
    first = client.post(BASE, headers=auth(pair), json=request(installation))
    assert first.status_code == 201
    record = first.json()['bootstrap']
    assert client.post(BASE, headers=auth(pair), json=request(installation)).json() == {
        'bootstrap': record}
    with TestClient(create_app(settings)) as reopened:
        assert reopened.get(BASE + '/' + record['id'], headers=auth(pair)).json() == {
            'bootstrap': record}
        assert reopened.post(BASE, headers=auth(pair), json=request(installation)).json() == {
            'bootstrap': record}


def test_only_exact_terminal_installation_can_allocate_one_bootstrap(server):
    app, client, _, _ = server
    pair, _, _, body = prepared(server)
    app.state.core.media_installations.backend = ExecutionBackend()
    queued = client.post('/api/v1/admin/media/installations',
                         headers=auth(pair), json=body).json()['installation']
    denied = client.post(BASE, headers=auth(pair), json=request(queued))
    assert denied.status_code == 409
    assert denied.json()['error']['code'] == 'media_installation_changed'
    assert client.get(BASE, headers=auth(pair)).json() == {
        'bootstraps': [], 'nextBefore': None}
    with app.state.core.db.connection() as connection:
        assert connection.execute('SELECT COUNT(*) FROM media_service_bootstraps').fetchone()[0] == 0


def test_request_rejects_revision_reuse_and_client_selected_credentials(server):
    app, client, _, _ = server
    pair, installation = installed(server)
    body = request(installation)
    first = client.post(BASE, headers=auth(pair), json=body)
    assert first.status_code == 201
    conflict = client.post(BASE, headers=auth(pair),
                           json=body | {'requestId': 'e' * 32})
    assert conflict.status_code == 409
    assert conflict.json()['error']['code'] == 'media_bootstrap_conflict'
    for extra in ({'password': SECRET}, {'username': 'admin'}, {'baseUrl': 'http://127.0.0.1'},
                  {'expectedInstallationRevision': True}, {'serviceId': 'jellyfin'}):
        response = client.post(BASE, headers=auth(pair), json=body | extra)
        assert response.status_code == 400
        assert SECRET not in response.text


def test_bootstrap_requires_current_ready_admin_and_bounds_reads(server):
    app, client, _, _ = server
    pair, installation = installed(server)
    record = client.post(BASE, headers=auth(pair), json=request(installation)).json()['bootstrap']
    member = app.state.core.admin.create_user(
        app.state.core.auth.principal(pair['accessToken']), 'member', 'member',
        'Synthetic member password 2026')
    member_pair = client.post('/api/v1/auth/login', json={
        'username': 'member', 'password': 'Synthetic member password 2026',
        'deviceName': 'Member tablet'}).json()
    assert client.get(BASE, headers=auth(member_pair)).status_code == 403
    assert client.get(BASE + '/' + 'f' * 32, headers=auth(pair)).status_code == 404
    assert client.get(BASE + '/' + record['id'], headers=auth(pair)).status_code == 200
    assert client.get(BASE + '?limit=0', headers=auth(pair)).status_code == 400
    client.post('/api/v1/auth/logout', headers=auth(pair))
    assert client.get(BASE + '/' + record['id'], headers=auth(pair)).status_code == 401
    assert member['user']['role'] == 'member'


@pytest.mark.parametrize('damage', ['ciphertext', 'nonce', 'state', 'table'])
def test_storage_damage_fails_closed_on_restart(server, damage):
    app, _client, settings, _ = server
    pair, installation = installed(server)
    app.state.core.media_service_bootstraps.create(
        app.state.core.auth.principal(pair['accessToken']), request(installation))
    with app.state.core.db.connection() as connection:
        if damage == 'ciphertext':
            connection.execute("UPDATE media_service_bootstraps SET ciphertext=x'00'")
        elif damage == 'nonce':
            connection.execute("UPDATE media_service_bootstraps SET nonce=x'00'")
        elif damage == 'state':
            connection.execute("PRAGMA ignore_check_constraints=ON")
            connection.execute("UPDATE media_service_bootstraps SET state='private-secret'")
        else:
            connection.execute('ALTER TABLE media_service_bootstraps RENAME TO media_service_bootstraps_old')
    with pytest.raises(Exception, match='invalid_media_service_bootstraps_storage'):
        create_app(settings)
