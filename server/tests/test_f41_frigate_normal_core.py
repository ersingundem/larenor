import pytest
from fastapi.testclient import TestClient
from conftest import ready, auth
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from support.f41_frigate_fixture import FrigateFixture, provision


@pytest.fixture
def frigate():
    upstream = FrigateFixture()
    yield upstream
    upstream.close()
    assert upstream.errors == []


def search(client, actor, root, cameras, **updates):
    body = {'schemaVersion': 1, 'query': 'red parcel', 'expectedIndexRevision': 1,
        'startMs': 1788609500000, 'endMs': 1788609700000, 'cameraIds': cameras, 'pageSize': 1, 'cursor': None}
    body.update(updates)
    return client.post(root + '/search', headers=auth(actor), json=body)


def test_normal_core_real_probes_registry_search_restart_and_private_sources(server, frigate):
    app, client, settings, _ = server
    actor = ready(server)
    root, setup, _, cameras, _ = provision(client, app.state.core, actor, frigate)
    context = client.get(root + '/context', headers=auth(actor))
    assert context.status_code == 200, context.text
    assert context.json()['cameraIds'] == sorted(cameras)
    page = search(client, actor, root, cameras)
    assert page.status_code == 200, page.text
    assert page.json()['mode'] == 'semantic_assisted'
    assert page.json()['results'][0]['summary'] == 'Red parcel at the door'
    assert page.json()['nextCursor'] is not None
    next_page = search(client, actor, root, cameras, cursor=page.json()['nextCursor'])
    assert next_page.status_code == 200, next_page.text
    assert next_page.json()['results'][0]['evidence'] != page.json()['results'][0]['evidence']
    assert frigate.token not in page.text and '1788609600.123-front' not in page.text
    assert 'PRIVATE-ONLY' not in client.get(setup, headers=auth(actor)).text
    assert not any(method == 'POST' for method, _ in frigate.calls)
    with TestClient(create_app(settings)) as restarted:
        current = search(restarted, actor, root, cameras)
        assert current.status_code == 200, current.text
        assert current.json()['results'][0]['evidence'] == page.json()['results'][0]['evidence']
        assert search(restarted, actor, root, cameras, cursor=page.json()['nextCursor']).status_code == 409


def test_real_frigate_password_login_cookie_becomes_private_bearer(server, frigate):
    frigate.frigate_credentials = {'username': 'fixture', 'password': 'synthetic-password-only'}
    app, client, _, _ = server
    actor = ready(server)
    root, _, _, cameras, _ = provision(client, app.state.core, actor, frigate)
    page = search(client, actor, root, cameras)
    assert page.status_code == 200
    assert frigate.jwt not in page.text
    assert frigate.frigate_credentials['password'] not in page.text
    assert ('POST', '/api/login') in frigate.calls
    assert all(path == '/api/login' for method, path in frigate.calls if method == 'POST')


def test_deleted_capture_retires_cursor_and_feedback_and_never_returns_old_event(server, frigate):
    app, client, _, _ = server; actor = ready(server)
    root, _, _, cameras, _ = provision(client, app.state.core, actor, frigate)
    page = search(client, actor, root, cameras).json()
    frigate.events.pop(0)
    assert search(client, actor, root, cameras, cursor=page['nextCursor']).status_code == 409
    body = {'schemaVersion': 1, 'requestId': 'a' * 32, 'query': 'red parcel',
        'expectedIndexRevision': 1, 'evidence': page['results'][0]['evidence'], 'reason': 'wrong_summary'}
    assert client.post(root + '/feedback', headers=auth(actor), json=body).status_code == 503
    fresh = search(client, actor, root, cameras)
    assert fresh.status_code == 200, fresh.text
    assert all(item['evidence'] != body['evidence'] for item in fresh.json()['results'])


def test_metadata_fallback_queries_real_events_and_feedback_is_query_bound(server, frigate):
    app, client, _, _ = server; actor = ready(server)
    root, _, _, cameras, _ = provision(client, app.state.core, actor, frigate)
    frigate.semantic = False
    page = search(client, actor, root, cameras).json()
    assert page['mode'] == 'local_metadata' and page['status'] == 'degraded'
    body = {'schemaVersion': 1, 'requestId': 'a' * 32, 'query': 'some other query',
        'expectedIndexRevision': 1, 'evidence': page['results'][0]['evidence'], 'reason': 'irrelevant'}
    assert client.post(root + '/feedback', headers=auth(actor), json=body).status_code == 409
    body['query'] = 'red parcel'
    reported = client.post(root + '/feedback', headers=auth(actor), json=body)
    assert reported.status_code == 200, reported.text
    fresh = search(client, actor, root, cameras)
    assert fresh.status_code == 200, fresh.text
    assert fresh.json()['results'] == []
    assert any(path.startswith('/api/events?') for _, path in frigate.calls)


@pytest.mark.parametrize('change', ['platform', 'device', 'service', 'provider_permissions'])
def test_changed_registry_service_or_permissions_retires_results(server, frigate, change):
    app, client, _, _ = server; actor = ready(server)
    root, _, _, cameras, services = provision(client, app.state.core, actor, frigate)
    if change == 'platform': frigate.registry_platform = 'template'
    elif change == 'device': frigate.device = 'f' * 32
    elif change == 'provider_permissions': frigate.allowed = ['back']
    else:
        changed = client.patch('/api/v1/admin/services/' + services['frigate']['id'], headers=auth(actor),
            json={'expectedRevision': 1, 'name': 'Replacement', 'baseUrl': frigate.url})
        assert changed.status_code == 200, changed.text
    response = search(client, actor, root, cameras)
    assert response.status_code == 409, response.text


@pytest.mark.parametrize('invalid', [False, {}, [{'id': '../escape'}],
    [FrigateFixture.event('other', 'forbidden')], [FrigateFixture.event('a', 'front')] * 2])
def test_bad_or_unauthorized_upstream_events_fail_closed(server, frigate, invalid):
    app, client, _, _ = server; actor = ready(server)
    root, _, _, cameras, _ = provision(client, app.state.core, actor, frigate)
    frigate.invalid_events = invalid
    response = search(client, actor, root, cameras)
    assert response.status_code in [409, 503], response.text
    assert 'results' not in response.json()


def test_sealed_source_inventory_deletion_fails_restart(server, frigate):
    app, client, settings, _ = server; actor = ready(server)
    provision(client, app.state.core, actor, frigate)
    with app.state.core.db.transaction() as connection:
        connection.execute("DELETE FROM camera_provider_records WHERE id='search-configuration'")
    with pytest.raises(StartupError, match='camera_profile_storage_invalid'):
        create_app(settings)


def test_real_authorized_clip_is_exact_mp4_with_digest_and_no_provider_url(server, frigate):
    import hashlib
    app, client, _, _ = server; actor = ready(server)
    root, _, _, cameras, _ = provision(client, app.state.core, actor, frigate)
    evidence = search(client, actor, root, cameras).json()['results'][0]['evidence']
    result = client.post(root + '/clip', headers=auth(actor), json=evidence)
    assert result.status_code == 200
    assert result.content == frigate.clip_bytes and result.content[4:8] == b'ftyp'
    assert result.headers['x-larenor-content-sha256'] == hashlib.sha256(result.content).hexdigest()
    assert result.headers['x-larenor-clip-id'] == evidence['clipId']
    assert set(result.headers['cache-control'].split(', ')) == {'no-store'}
    assert 2**31 < evidence['captureRevision'] <= 2**53 - 1
    assert 'location' not in result.headers and 'set-cookie' not in result.headers
    forged = {**evidence, 'eventId': 'f' * 32}
    assert client.post(root + '/clip', headers=auth(actor), json=forged).status_code == 409
    assert sum(path.endswith('/clip.mp4') for _, path in frigate.calls) == 1


@pytest.mark.parametrize('change', ['deleted', 'metadata', 'permissions', 'mime', 'container'])
def test_clip_change_during_download_never_releases_media(server, frigate, change):
    app, client, _, _ = server; actor = ready(server)
    root, _, _, cameras, _ = provision(client, app.state.core, actor, frigate)
    evidence = search(client, actor, root, cameras).json()['results'][0]['evidence']
    if change == 'deleted': frigate.on_clip = lambda: frigate.events.clear()
    elif change == 'metadata': frigate.on_clip = lambda: frigate.events[0]['data'].update(description='Changed')
    elif change == 'permissions': frigate.on_clip = lambda: frigate.allowed.clear()
    elif change == 'mime': frigate.clip_content_type = 'text/html'
    else: frigate.clip_bytes = b'<html>not a clip</html>'
    response = client.post(root + '/clip', headers=auth(actor), json=evidence)
    assert response.status_code in [409, 503], response.status_code
    assert response.headers['content-type'] == 'application/json'


def test_old_search_clip_expires_and_does_not_survive_restart(server, frigate):
    app, client, settings, clock = server; actor = ready(server)
    root, _, _, cameras, _ = provision(client, app.state.core, actor, frigate)
    evidence = search(client, actor, root, cameras).json()['results'][0]['evidence']
    with TestClient(create_app(settings)) as restarted:
        assert restarted.post(root + '/clip', headers=auth(actor), json=evidence).status_code == 409
    clock.now += 121
    assert client.post(root + '/clip', headers=auth(actor), json=evidence).status_code == 409
    assert not any(path.endswith('/clip.mp4') for _, path in frigate.calls)
