import json

import pytest

from conftest import auth
from larenor_server.plugins.music_playback_models import (
    MusicPlaybackReadback, MusicPlaybackWorkerResult, VerifiedMusicPlayer,
)
from larenor_server.plugins.music_provider_setup_models import (
    ProviderSetupWorkerResult,
)
from test_music_provider_setups import BASE as PROVIDERS_BASE, create_setup, external


BASE = '/api/v1/admin/media/music-assistant/playback'


def player(identifier='homepod-living', *, group=(), volume=34):
    return VerifiedMusicPlayer(
        playerId=identifier, name='Living HomePod', provider='airplay--main',
        targetKind='homepod' if not group else 'airplay_group',
        available=True, enabled=True, playbackState='paused',
        volumeLevel=volume, muted=False, groupMembers=list(group),
        queueId=identifier,
        capabilities=['play', 'pause', 'stop', 'next_previous',
                      'volume_set', 'volume_mute', 'queue'])


def provider_ready(server):
    app, client, _, _ = server
    pair, setup = create_setup(server)
    discovered = app.state.core.music_provider_setups.record_initial_discovery(
        setup['id'], 1, external('spotify'))

    class Provider:
        def execute_music_provider_setup(self, _action, *, deadline, gate):
            assert gate() is True
            return ProviderSetupWorkerResult(
                state='ready', providerDomain='spotify',
                providerInstanceId='spotify--fixture')

    app.state.core.music_provider_setups.backend = Provider()
    completed = client.post(PROVIDERS_BASE + '/' + setup['id'] + '/resume',
                            headers=auth(pair), json={
                                'expectedRevision': discovered['revision']})
    assert completed.status_code == 200
    readiness = app.state.core.music_assistant_core.get(
        app.state.core.auth.authenticate(pair['accessToken']),
        setup['installationId'])['readiness']
    return pair, setup, readiness


class PlaybackWorker:
    def __init__(self, players):
        self.players = players
        self.calls = []

    def read_music_players(self, _private, *, deadline, gate):
        assert gate() is True
        return MusicPlaybackReadback(players=self.players)

    def execute_music_playback(self, action, *, deadline, gate):
        assert gate() is True
        self.calls.append(action)
        return MusicPlaybackWorkerResult(
            state='succeeded', target=self.players[0])


def discovered(server, players=None):
    app, client, _, _ = server
    pair, setup, readiness = provider_ready(server)
    worker = PlaybackWorker(players or [player()])
    app.state.core.music_playback.backend = worker
    response = client.post(BASE + '/refresh', headers=auth(pair), json={
        'requestId': 'c' * 32,
        'installationId': setup['installationId'],
        'expectedInstallationRevision': setup['installationRevision'],
        'expectedCoreRevision': readiness['revision'],
    })
    assert response.status_code == 200, response.text
    return pair, setup, readiness, worker, response.json()['playback']


def test_authenticated_player_readback_exposes_exact_airplay_homepod_capabilities(server):
    pair, setup, readiness, _worker, playback = discovered(server, [
        player(), player('homepod-kitchen'),
        player('whole-home', group=('homepod-living', 'homepod-kitchen'))])
    assert playback['installationId'] == setup['installationId']
    assert playback['coreRevision'] == readiness['revision']
    assert playback['installAvailable'] is False
    assert playback['players'][0]['targetKind'] == 'homepod'
    assert playback['players'][2]['targetKind'] == 'airplay_group'
    assert playback['players'][2]['groupMembers'] == [
        'homepod-living', 'homepod-kitchen']
    saved = server[1].get(BASE + '/' + setup['installationId'],
                          headers=auth(pair))
    assert saved.status_code == 200 and saved.json()['playback'] == playback


@pytest.mark.parametrize(('operation', 'changes'), [
    ('play', {}), ('pause', {}), ('stop', {}), ('next', {}), ('previous', {}),
    ('volume', {'volumeLevel': 55}), ('mute', {'muted': True}),
    ('queue_add', {'mediaUris': ['spotify://track/fixture']}),
    ('queue_replace', {'mediaUris': ['library://playlist/fixture']}),
    ('queue_clear', {}),
])
def test_each_explicit_control_is_idempotent_and_revision_group_bound(
        server, operation, changes):
    pair, setup, readiness, worker, playback = discovered(server)
    body = {
        'requestId': 'd' * 32,
        'installationId': setup['installationId'],
        'expectedInstallationRevision': setup['installationRevision'],
        'expectedCoreRevision': readiness['revision'],
        'expectedPlayerRevision': playback['revision'],
        'targetId': 'homepod-living', 'expectedProvider': 'airplay--main',
        'expectedTargetKind': 'homepod',
        'expectedQueueId': 'homepod-living', 'expectedGroupMembers': [],
        'operation': operation, **changes,
    }
    first = server[1].post(BASE + '/commands', headers=auth(pair), json=body)
    assert first.status_code == 201, first.text
    receipt = first.json()['receipt']
    assert receipt['state'] == 'succeeded' and receipt['operation'] == operation
    assert receipt['installAvailable'] is False
    again = server[1].post(BASE + '/commands', headers=auth(pair), json=body)
    assert again.status_code == 201 and again.json() == first.json()
    assert len(worker.calls) == 1
    encoded = json.dumps(first.json())
    assert 'private-mass-token' not in encoded


def test_stale_revision_or_group_members_never_reaches_worker(server):
    pair, setup, readiness, worker, playback = discovered(server)
    base = {
        'requestId': 'e' * 32, 'installationId': setup['installationId'],
        'expectedInstallationRevision': setup['installationRevision'],
        'expectedCoreRevision': readiness['revision'],
        'expectedPlayerRevision': playback['revision'],
        'targetId': 'homepod-living', 'expectedProvider': 'airplay--main',
        'expectedTargetKind': 'homepod',
        'expectedQueueId': 'homepod-living', 'expectedGroupMembers': [],
        'operation': 'pause'}
    for change in [
        {'expectedPlayerRevision': playback['revision'] + 1},
        {'expectedGroupMembers': ['unexpected-member']},
    ]:
        body = {**base, **change}
        body['requestId'] = ('f' if change.get('expectedGroupMembers') else 'e') * 32
        response = server[1].post(BASE + '/commands', headers=auth(pair), json=body)
        assert response.status_code == 409
    assert worker.calls == []


def test_provider_must_remain_verified_for_every_player_effect(server):
    app, client, _, _ = server
    pair, setup, readiness, worker, playback = discovered(server)
    with app.state.core.db.transaction() as connection:
        row = connection.execute(
            'SELECT * FROM music_provider_setups WHERE installation_id=?',
            (setup['installationId'],)).fetchone()
        stored = app.state.core.music_provider_setups._decode(row)
        changed = dict(row)
        changed['revision'] += 1
        app.state.core.music_provider_setups._save(
            connection, changed, stored.model_copy(update={'status': 'cancelled'}))
    response = client.post(BASE + '/commands', headers=auth(pair), json={
        'requestId': 'a' * 32, 'installationId': setup['installationId'],
        'expectedInstallationRevision': setup['installationRevision'],
        'expectedCoreRevision': readiness['revision'],
        'expectedPlayerRevision': playback['revision'],
        'targetId': 'homepod-living', 'expectedProvider': 'airplay--main',
        'expectedTargetKind': 'homepod',
        'expectedQueueId': 'homepod-living', 'expectedGroupMembers': [],
        'operation': 'pause'})
    assert response.status_code == 409
    assert response.json()['error']['code'] == 'music_provider_not_ready'
    assert worker.calls == []


def test_uncertain_effect_is_journaled_and_never_retried_automatically(server):
    app, client, _, _ = server
    pair, setup, readiness, worker, playback = discovered(server)

    def fail(_action, *, deadline, gate):
        worker.calls.append('attempt')
        raise RuntimeError('private effect failure')

    worker.execute_music_playback = fail
    body = {
        'requestId': '9' * 32, 'installationId': setup['installationId'],
        'expectedInstallationRevision': setup['installationRevision'],
        'expectedCoreRevision': readiness['revision'],
        'expectedPlayerRevision': playback['revision'],
        'targetId': 'homepod-living', 'expectedProvider': 'airplay--main',
        'expectedTargetKind': 'homepod',
        'expectedQueueId': 'homepod-living', 'expectedGroupMembers': [],
        'operation': 'pause'}
    first = client.post(BASE + '/commands', headers=auth(pair), json=body)
    assert first.status_code == 503 and 'private effect failure' not in first.text
    second = client.post(BASE + '/commands', headers=auth(pair), json=body)
    assert second.status_code == 201
    assert second.json()['receipt']['state'] == 'needs_attention'
    assert second.json()['receipt']['code'] == 'effect_unknown'
    assert worker.calls == ['attempt']
