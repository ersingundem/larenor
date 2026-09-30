"""Durable private event seals use normal Core and actual TCP provider guards."""

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.errors import ApiError
from support.f41_frigate_fixture import FrigateFixture, provision


@pytest.fixture
def bound(server):
    app, client, _settings, _clock = server
    upstream = FrigateFixture()
    pair = ready(server)
    root, _setup, _body, cameras, _services = provision(client, app.state.core, pair, upstream)
    response = client.post(root + '/search', headers=auth(pair), json={
        'schemaVersion': 1, 'query': 'red parcel', 'expectedIndexRevision': 1,
        'startMs': 1788609500000, 'endMs': 1788609700000,
        'cameraIds': cameras, 'pageSize': 1, 'cursor': None})
    assert response.status_code == 200, response.text
    evidence = response.json()['results'][0]['evidence']
    core = app.state.core
    actor = core.auth.authenticate(pair['accessToken'])
    runtime = core.camera_search_runtime
    facts = runtime.private_event_binding(core, actor, core.context.coreId, core.context.homeId,
        evidence['cameraId'], evidence['eventId'])
    yield upstream, pair, actor, evidence, facts
    upstream.close()
    assert upstream.errors == []


def test_seal_survives_restart_and_search_cache_expiry(server, bound):
    _upstream, pair, _actor, evidence, facts = bound
    server[3].now += 121
    with TestClient(create_app(server[2])) as restarted:
        core = restarted.app.state.core
        actor = core.auth.authenticate(pair['accessToken'])
        actual = core.camera_search_runtime.authorize_private_event_binding(core, actor, facts['seal'])
        assert actual['evidence'].model_dump(mode='json') == evidence
        assert actual['cameraRevision'] == facts['cameraRevision']
        assert 1 <= actual['cameraRevision'] <= 2**52
        clip = core.camera_search_runtime.read_private_event_clip(core, actor, facts['seal'], 64 * 1024 * 1024)
        assert clip == bound[0].clip_bytes
        assert evidence['eventId'] not in facts['seal']
        assert '1788609600.123-front' not in facts['seal']


def test_original_event_retention_does_not_block_share_authority(server, bound):
    upstream, _pair, actor, _evidence, facts = bound
    upstream.events.clear()
    core = server[0].state.core
    assert core.camera_search_runtime.authorize_private_event_binding(core, actor, facts['seal']) == facts
    with pytest.raises(ApiError):
        core.camera_search_runtime.read_private_event_clip(core, actor, facts['seal'], 64 * 1024 * 1024)


@pytest.mark.parametrize('change', ['tamper', 'expiry', 'permissions', 'cancelled', 'event_metadata'])
def test_sealed_clip_fails_closed_without_replay(server, bound, change):
    upstream, _pair, actor, _evidence, facts = bound
    core = server[0].state.core
    seal = facts['seal']
    if change == 'tamper':
        seal = ('a' if seal[0] != 'a' else 'b') + seal[1:]
    elif change == 'expiry':
        server[3].now += 7 * 86400 + 1
    elif change == 'permissions':
        upstream.allowed.clear()
    elif change == 'event_metadata':
        upstream.events[0]['data']['description'] = 'changed'
    with pytest.raises(ApiError):
        core.camera_search_runtime.read_private_event_clip(core, actor, seal,
            64 * 1024 * 1024, cancelled=lambda: change == 'cancelled')
    assert not any(path.endswith('/clip.mp4') for _, path in upstream.calls)


def test_permission_changes_during_sealed_clip_read_never_release_bytes(server, bound):
    upstream, _pair, actor, _evidence, facts = bound
    core = server[0].state.core
    upstream.on_clip = lambda: upstream.allowed.clear()
    with pytest.raises(ApiError):
        core.camera_search_runtime.read_private_event_clip(core, actor, facts['seal'], 64 * 1024 * 1024)
