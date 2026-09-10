"""Authenticated Music Assistant Core readiness and automatic peer wiring."""

import json

import pytest
from fastapi.testclient import TestClient

from conftest import auth
from larenor_server.app import create_app
from larenor_server.errors import ApiError
from larenor_server.plugins.music_assistant_core import AuthenticatedMusicAssistantReadback
from test_media_installations_api import ExecutionBackend, prepared
from test_services import create as create_service


BASE = '/api/v1/admin/media/music-assistant'
TOKEN = 'synthetic-music-assistant-token-never-public'


def installed(server):
    app, client, _, _ = server
    pair, _, _, body = prepared(server)
    app.state.core.media_installations.backend = ExecutionBackend()
    queued = client.post('/api/v1/admin/media/installations', headers=auth(pair), json={
        **body, 'serviceId': 'music_assistant'}).json()['installation']
    terminal = app.state.core.media_installations.tick()['installation']
    assert terminal['state'] == 'container_started'
    return pair, queued['id'], terminal['revision']


def authenticated_peer(server, pair, kind):
    app, client, _, _ = server
    credential = {'token': 'synthetic-' + kind + '-credential'}
    service = create_service(
        client, pair, name='Managed ' + kind, kind=kind,
        baseUrl='http://fixture.invalid/' + kind, credentials=credential)
    actor = app.state.core.auth.authenticate(pair['accessToken'])
    app.state.core.services.record_verification(
        actor, service['id'], service['revision'], state='authenticated', version='2026.9')
    return service


def readback():
    return AuthenticatedMusicAssistantReadback(
        token=TOKEN, serverId='mass-fixture', serverVersion='2.8.0', schemaVersion=29)


def test_worker_readback_is_encrypted_and_auto_wires_verified_managed_peers(server):
    app, client, settings, _ = server
    pair, installation_id, installation_revision = installed(server)
    ha = authenticated_peer(server, pair, 'home_assistant')
    jellyfin = authenticated_peer(server, pair, 'jellyfin')

    record = app.state.core.music_assistant_core.record_authenticated_readback(
        installation_id, installation_revision, readback())
    assert record == {
        'installationId': installation_id,
        'installationRevision': installation_revision,
        'revision': 1,
        'state': 'verified',
        'serverVersion': '2.8.0',
        'schemaVersion': 29,
        'homeAssistant': {'serviceId': ha['id'], 'serviceRevision': 1},
        'jellyfin': {'serviceId': jellyfin['id'], 'serviceRevision': 1},
        'errorCode': None,
        'installAvailable': False,
    }
    response = client.get(BASE + '/' + installation_id, headers=auth(pair))
    assert response.status_code == 200 and response.json()['readiness'] == record
    assert TOKEN not in response.text and 'fixture.invalid' not in response.text
    with app.state.core.db.connection() as connection:
        dump = '\n'.join(connection.iterdump())
    assert TOKEN not in dump and 'mass-fixture' not in dump
    with TestClient(create_app(settings)) as restarted:
        persisted = restarted.get(BASE + '/' + installation_id, headers=auth(pair))
        assert persisted.json()['readiness'] == record


def test_peer_revision_change_fails_closed_without_exposing_old_credentials(server):
    app, client, _, _ = server
    pair, installation_id, installation_revision = installed(server)
    ha = authenticated_peer(server, pair, 'home_assistant')
    authenticated_peer(server, pair, 'jellyfin')
    app.state.core.music_assistant_core.record_authenticated_readback(
        installation_id, installation_revision, readback())

    changed = client.patch('/api/v1/admin/services/' + ha['id'], headers=auth(pair), json={
        'expectedRevision': 1, 'name': 'Renamed HA', 'baseUrl': ha['baseUrl']})
    assert changed.status_code == 200 and changed.json()['service']['revision'] == 2
    response = client.get(BASE + '/' + installation_id, headers=auth(pair))
    assert response.status_code == 200
    readiness = response.json()['readiness']
    assert readiness['state'] == 'needs_attention'
    assert readiness['errorCode'] == 'dependency_changed'
    assert readiness['installAvailable'] is False
    assert TOKEN not in json.dumps(readiness)


@pytest.mark.parametrize('problem', ['missing', 'ambiguous', 'unverified'])
def test_discovery_rejects_missing_ambiguous_or_unverified_dependencies(server, problem):
    app, client, _, _ = server
    pair, installation_id, installation_revision = installed(server)
    authenticated_peer(server, pair, 'home_assistant')
    if problem != 'missing':
        authenticated_peer(server, pair, 'jellyfin')
    if problem == 'ambiguous':
        authenticated_peer(server, pair, 'jellyfin')
    if problem == 'unverified':
        service = create_service(
            client, pair, name='Unverified Jellyfin', kind='jellyfin',
            baseUrl='http://fixture.invalid/unverified', credentials={'token': 'private'})
        # The authenticated peer is made stale, leaving only an unverified candidate.
        with app.state.core.db.transaction() as connection:
            connection.execute('DELETE FROM service_connections WHERE id!=? AND id IN '
                               '(SELECT id FROM service_connections)', (service['id'],))
    expected = 'music_assistant_wiring_ambiguous' if problem == 'ambiguous' else 'music_assistant_dependency_unverified'
    with pytest.raises(ApiError, match='^' + expected + '$'):
        app.state.core.music_assistant_core.record_authenticated_readback(
            installation_id, installation_revision, readback())
    with app.state.core.db.connection() as connection:
        assert connection.execute('SELECT COUNT(*) FROM music_assistant_core').fetchone()[0] == 0


def test_readback_is_exact_bounded_and_never_available_before_verified_install(server):
    app, client, _, _ = server
    pair, _, _, body = prepared(server)
    app.state.core.media_installations.backend = ExecutionBackend()
    queued = client.post('/api/v1/admin/media/installations', headers=auth(pair), json={
        **body, 'serviceId': 'jellyfin'}).json()['installation']
    authenticated_peer(server, pair, 'home_assistant')
    authenticated_peer(server, pair, 'jellyfin')
    with pytest.raises(ApiError, match='^music_assistant_installation_changed$'):
        app.state.core.music_assistant_core.record_authenticated_readback(
            queued['id'], queued['revision'], readback())
    assert TOKEN not in repr(readback())
    assert client.get(BASE + '/' + queued['id'], headers=auth(pair)).status_code == 404


def test_http_surface_is_read_only_admin_scoped_and_strict(server):
    app, client, _, _ = server
    pair, installation_id, revision = installed(server)
    authenticated_peer(server, pair, 'home_assistant')
    authenticated_peer(server, pair, 'jellyfin')
    app.state.core.music_assistant_core.record_authenticated_readback(
        installation_id, revision, readback())
    assert client.get(BASE + '/' + installation_id).status_code == 401
    assert client.post(BASE + '/' + installation_id, headers=auth(pair), json={
        'token': TOKEN, 'endpoint': 'http://attacker.invalid'}).status_code == 405
    schema = client.get('/api/v1/openapi.json', headers=auth(pair)).json()
    path = '/api/v1/admin/media/music-assistant/{installation_id}'
    assert set(schema['paths'][path]) == {'get'}
    assert TOKEN not in json.dumps(schema)
