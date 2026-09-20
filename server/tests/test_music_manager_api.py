import json

from conftest import auth
from larenor_server.plugins.music_playback_models import (
    MusicCatalogItem, MusicCatalogWorkerResult, VerifiedMusicPlayer,
)
from test_music_playback import BASE, PlaybackWorker, player, provider_ready, queue


MANAGER = '/api/v1/admin/media/music-assistant/manager'
PRIVATE_TOKEN = 'private-mass-token'


def cast_player():
    return VerifiedMusicPlayer(
        playerId='cast-kitchen', name='Kitchen Cast',
        provider='chromecast--main', targetKind='cast', available=True,
        enabled=True, playbackState='paused', volumeLevel=25, muted=False,
        groupMembers=[], queueId='cast-kitchen', positionSeconds=5,
        capabilities=['play', 'pause', 'seek', 'stop', 'queue'])


class ManagerWorker(PlaybackWorker):
    def __init__(self):
        super().__init__([player(), cast_player()])
        self.queues = [queue()]
        self.searches = []

    def search_music_catalog(self, action, *, deadline, gate):
        assert gate() is True
        self.searches.append(action)
        return MusicCatalogWorkerResult(items=[MusicCatalogItem(
            uri='spotify://track/result', name='Result', mediaType='track',
            providerInstanceId=action.request.providerInstanceId,
            artists=['Artist'])])


def ready_manager(server):
    app, client, _, _ = server
    pair, setup, readiness = provider_ready(server)
    worker = ManagerWorker()
    app.state.core.music_playback.backend = worker
    response = client.post(MANAGER + '/refresh', headers=auth(pair), json={
        'requestId': '1' * 32,
        'installationId': setup['installationId'],
        'expectedInstallationRevision': setup['installationRevision'],
        'expectedCoreRevision': readiness['revision'],
    })
    assert response.status_code == 200, response.text
    assert response.status_code == 200, response.text
    return pair, setup, readiness, worker, response.json()['manager']


def search_body(setup, readiness, manager):
    provider = manager['providers'][0]
    return {
        'requestId': '2' * 32,
        'installationId': setup['installationId'],
        'expectedInstallationRevision': setup['installationRevision'],
        'expectedCoreRevision': readiness['revision'],
        'expectedManagerRevision': manager['revision'],
        'providerSetupId': provider['setupId'],
        'expectedProviderRevision': provider['revision'],
        'providerDomain': provider['providerDomain'],
        'providerInstanceId': provider['providerInstanceId'],
        'query': 'Result', 'mediaTypes': ['track'], 'limit': 10,
        'libraryOnly': False,
    }


def test_one_manager_surface_aggregates_provider_catalog_queue_and_receivers(
        server, caplog):
    pair, setup, readiness, worker, manager = ready_manager(server)
    assert manager['providers'] == [{
        'setupId': manager['providers'][0]['setupId'],
        'revision': manager['providers'][0]['revision'],
        'providerDomain': 'spotify',
        'providerInstanceId': 'spotify--fixture',
        'catalogAvailable': True,
    }]
    assert manager['queues'][0]['queueId'] == 'homepod-living'
    assert [item['targetKind'] for item in manager['receivers']] == [
        'homepod', 'cast']

    response = server[1].post(
        MANAGER + '/catalog/search', headers=auth(pair),
        json=search_body(setup, readiness, manager))
    assert response.status_code == 200, response.text
    assert response.json()['catalog']['items'] == [{
        'uri': 'spotify://track/result', 'name': 'Result',
        'mediaType': 'track', 'providerInstanceId': 'spotify--fixture',
        'artists': ['Artist'],
    }]
    assert len(worker.searches) == 1
    command = server[1].post(
        MANAGER + '/commands', headers=auth(pair), json={
            'requestId': '3' * 32,
            'installationId': setup['installationId'],
            'expectedInstallationRevision': setup['installationRevision'],
            'expectedCoreRevision': readiness['revision'],
            'expectedPlayerRevision': manager['revision'],
            'targetId': 'homepod-living',
            'expectedProvider': 'airplay--main',
            'expectedTargetKind': 'homepod',
            'expectedQueueId': 'homepod-living',
            'expectedGroupMembers': [], 'operation': 'pause',
        })
    assert command.status_code == 201, command.text
    assert command.json()['receipt']['code'] == 'authenticated_readback'
    public = json.dumps({'manager': manager, 'catalog': response.json()})
    assert PRIVATE_TOKEN not in public
    assert PRIVATE_TOKEN not in repr(worker.searches[0])
    assert PRIVATE_TOKEN not in caplog.text
    schema = server[1].get('/api/v1/openapi.json', headers=auth(pair)).json()
    search_schema = schema['components']['schemas']['SearchMusicCatalogRequest']
    manager_schema = schema['components']['schemas']['MusicManagerState']
    assert 'token' not in json.dumps([search_schema, manager_schema]).lower()


def test_provider_revision_drift_fails_closed_before_catalog_worker(server):
    app, client, _, _ = server
    pair, setup, readiness, worker, manager = ready_manager(server)
    provider = manager['providers'][0]
    with app.state.core.db.transaction() as connection:
        row = connection.execute(
            'SELECT * FROM music_provider_setups WHERE id=?',
            (provider['setupId'],)).fetchone()
        stored = app.state.core.music_provider_setups._decode(row)
        changed = dict(row)
        changed['revision'] += 1
        app.state.core.music_provider_setups._save(connection, changed, stored)

    state = client.get(
        MANAGER + '/' + setup['installationId'], headers=auth(pair))
    assert state.status_code == 409
    assert state.json()['error']['code'] == 'music_provider_changed'
    search = client.post(
        MANAGER + '/catalog/search', headers=auth(pair),
        json=search_body(setup, readiness, manager))
    assert search.status_code == 409
    assert search.json()['error']['code'] == 'music_provider_changed'
    assert worker.searches == []
    assert PRIVATE_TOKEN not in state.text + search.text


def test_catalog_worker_result_from_wrong_provider_is_never_public(server):
    pair, setup, readiness, worker, manager = ready_manager(server)

    def wrong(action, *, deadline, gate):
        return MusicCatalogWorkerResult(items=[MusicCatalogItem(
            uri='apple_music://track/wrong', name='Wrong', mediaType='track',
            providerInstanceId='apple_music--other')])

    worker.search_music_catalog = wrong
    response = server[1].post(
        MANAGER + '/catalog/search', headers=auth(pair),
        json=search_body(setup, readiness, manager))
    assert response.status_code == 503
    assert response.json()['error']['code'] == 'music_catalog_worker_unavailable'
    assert 'Wrong' not in response.text and PRIVATE_TOKEN not in response.text


def test_provider_revision_drift_during_catalog_readback_discards_result(server):
    app, client, _, _ = server
    pair, setup, readiness, worker, manager = ready_manager(server)
    provider = manager['providers'][0]

    def drift(action, *, deadline, gate):
        assert gate() is True
        with app.state.core.db.transaction() as connection:
            row = connection.execute(
                'SELECT * FROM music_provider_setups WHERE id=?',
                (provider['setupId'],)).fetchone()
            stored = app.state.core.music_provider_setups._decode(row)
            changed = dict(row)
            changed['revision'] += 1
            app.state.core.music_provider_setups._save(
                connection, changed, stored)
        return MusicCatalogWorkerResult(items=[MusicCatalogItem(
            uri='spotify://track/stale', name='Stale', mediaType='track',
            providerInstanceId=action.request.providerInstanceId)])

    worker.search_music_catalog = drift
    response = client.post(
        MANAGER + '/catalog/search', headers=auth(pair),
        json=search_body(setup, readiness, manager))
    assert response.status_code == 503
    assert response.json()['error']['code'] == 'music_catalog_worker_unavailable'
    assert 'Stale' not in response.text and PRIVATE_TOKEN not in response.text
