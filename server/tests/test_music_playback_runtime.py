import json
import os
from pathlib import Path
import tempfile
import threading
import time

import pytest

from larenor_server.plugins.installation_ipc import (
    InstallationWorkerClient, InstallationWorkerServer,
)
from larenor_server.plugins.music_playback_models import (
    MusicCatalogItem, MusicCatalogWorkerResult, MusicPlaybackCommandRequest,
    MusicPlaybackReadback, MusicPlaybackWorkerResult,
    PrivateMusicCatalogAction, PrivateMusicPlaybackAction,
    PrivateMusicPlaybackAuthority, SearchMusicCatalogRequest,
)
from larenor_server.plugins.music_playback_runtime import MusicPlaybackRuntime


class Response:
    status = 200

    def __init__(self, value):
        self.value = value

    def read(self, _limit):
        return json.dumps(self.value).encode()


class Connection:
    def __init__(self, responses, calls):
        self.responses, self.calls = responses, calls

    def request(self, method, path, body, headers):
        self.calls.append((method, path, json.loads(body), headers))

    def getresponse(self):
        return Response(self.responses.pop(0))

    def close(self):
        pass


def raw_player(identifier='homepod-living', *, group=None, state='paused',
               provider='airplay--main', model='HomePod mini', position=12):
    return {
        'player_id': identifier, 'provider': provider,
        'name': 'Living HomePod', 'available': True, 'enabled': True,
        'playback_state': state, 'volume_level': 32,
        'volume_muted': False, 'group_members': group or [],
        'active_source': identifier, 'supported_features': [
            'pause', 'seek', 'next_previous'], 'volume_control': 'native',
        'mute_control': 'native',
        'elapsed_time': position,
        'device_info': {'manufacturer': 'Apple', 'model': model},
    }


def raw_queue(identifier='homepod-living', *, count=1,
              uri='spotify://track/current', position=12):
    return {
        'queue_id': identifier, 'active': count > 0, 'items': count,
        'elapsed_time': position,
        'current_item': None if uri is None else {'uri': uri},
    }


def request(operation='queue_add', **changes):
    body = {
        'requestId': 'a' * 32, 'installationId': 'b' * 32,
        'expectedInstallationRevision': 3, 'expectedCoreRevision': 2,
        'expectedPlayerRevision': 1, 'targetId': 'homepod-living',
        'expectedProvider': 'airplay--main', 'expectedTargetKind': 'homepod',
        'expectedQueueId': 'homepod-living',
        'expectedGroupMembers': [], 'operation': operation,
        'mediaUris': ['spotify://track/fixture']
        if operation in {'queue_add', 'queue_replace'} else [],
        'positionSeconds': 48 if operation == 'seek' else None,
    }
    body.update(changes)
    return MusicPlaybackCommandRequest(**body)


def test_authenticated_discovery_derives_homepod_and_exact_airplay_group():
    calls = []
    responses = [
        [{'queue_id': 'homepod-living'}, {'queue_id': 'whole-home'}],
        [raw_player(), raw_player('homepod-kitchen'),
         raw_player('whole-home', group=['homepod-living', 'homepod-kitchen'])],
    ]
    runtime = MusicPlaybackRuntime(lambda _timeout: Connection(responses, calls))
    result = runtime.read(PrivateMusicPlaybackAuthority(
        installationId='b' * 32, token='private-token'),
        deadline=time.monotonic() + 2)
    assert [item.targetKind for item in result.players] == [
        'homepod', 'homepod', 'airplay_group']
    assert result.players[2].groupMembers == [
        'homepod-living', 'homepod-kitchen']
    assert [call[2]['command'] for call in calls] == [
        'player_queues/all', 'players/all']
    assert all(call[3]['Authorization'] == 'Bearer private-token'
               for call in calls)


def test_authenticated_discovery_exposes_cast_and_seek_capabilities():
    calls = []
    cast = raw_player(
        'cast-kitchen', provider='chromecast--main', model='Nest Audio')
    responses = [
        [raw_queue(), raw_queue('cast-kitchen')], [raw_player(), cast],
    ]
    runtime = MusicPlaybackRuntime(lambda _timeout: Connection(responses, calls))
    result = runtime.read(PrivateMusicPlaybackAuthority(
        installationId='b' * 32, token='private-token'),
        deadline=time.monotonic() + 2)
    assert [item.targetKind for item in result.players] == ['homepod', 'cast']
    assert all('seek' in item.capabilities for item in result.players)
    assert result.queues[0].currentItemUri == 'spotify://track/current'


def test_queue_add_is_one_explicit_effect_with_pre_and_post_readback():
    calls = []
    responses = [
        raw_player(),
        [raw_queue()],
        None, raw_player(),
        [raw_queue(count=2)],
    ]
    runtime = MusicPlaybackRuntime(lambda _timeout: Connection(responses, calls))
    action = PrivateMusicPlaybackAction(
        request=request(), token='private-token')
    result = runtime.execute(action, deadline=time.monotonic() + 2)
    assert result.state == 'succeeded'
    assert [call[2]['command'] for call in calls] == [
        'players/get', 'player_queues/all', 'player_queues/play_media',
        'players/get', 'player_queues/all']
    effect = calls[2][2]['args']
    assert effect == {'queue_id': 'homepod-living',
                      'media': ['spotify://track/fixture'],
                      'option': 'add', 'radio_mode': False}
    assert 'private-token' not in repr(action)


@pytest.mark.parametrize(('operation', 'before_state', 'after_state', 'extra'), [
    ('play', 'paused', 'playing', {}),
    ('pause', 'playing', 'paused', {}),
    ('seek', 'playing', 'playing', {'positionSeconds': 48}),
])
def test_transport_success_requires_matching_post_effect_readback(
        operation, before_state, after_state, extra):
    responses = [raw_player(state=before_state), [raw_queue()], None,
                 raw_player(state=after_state, position=extra.get(
                     'positionSeconds', 12))]
    if operation == 'seek':
        responses.append([raw_queue(position=48)])
    calls = []
    runtime = MusicPlaybackRuntime(lambda _timeout: Connection(responses, calls))
    result = runtime.execute(PrivateMusicPlaybackAction(
        request=request(operation, **extra), token='private-token'),
        deadline=time.monotonic() + 2)
    assert result.state == 'succeeded'
    if operation == 'seek':
        assert calls[2][2]['command'] == 'player_queues/seek'
        assert result.queue.positionSeconds == 48


@pytest.mark.parametrize(('operation', 'after_state', 'extra', 'after_queue'), [
    ('play', 'paused', {}, None),
    ('pause', 'playing', {}, None),
    ('seek', 'playing', {'positionSeconds': 48}, raw_queue(position=10)),
    ('queue_add', 'paused', {}, raw_queue(count=1)),
])
def test_transport_never_succeeds_without_changed_readback(
        operation, after_state, extra, after_queue):
    responses = [raw_player(state='playing'), [raw_queue()], None,
                 raw_player(state=after_state)]
    if after_queue is not None:
        responses.append([after_queue])
    runtime = MusicPlaybackRuntime(
        lambda _timeout: Connection(responses, []))
    with pytest.raises(Exception, match='music_playback_readback_unverified'):
        runtime.execute(PrivateMusicPlaybackAction(
            request=request(operation, **extra), token='private-token'),
            deadline=time.monotonic() + 2)


def catalog_request():
    return SearchMusicCatalogRequest(
        requestId='f' * 32, installationId='b' * 32,
        expectedInstallationRevision=3, expectedCoreRevision=2,
        expectedManagerRevision=1, providerSetupId='c' * 32,
        expectedProviderRevision=4, providerDomain='spotify',
        providerInstanceId='spotify--fixture', query='Discovery',
        mediaTypes=['track'], limit=10, libraryOnly=False)


def test_catalog_search_filters_exact_provider_and_never_exposes_token():
    calls = []
    responses = [{
        'tracks': [
            {'uri': 'spotify://track/right', 'name': 'Right',
             'provider': 'spotify--fixture',
             'artists': [{'name': 'Artist'}]},
            {'uri': 'spotify://track/other', 'name': 'Other',
             'provider': 'spotify--other', 'artists': []},
        ],
    }]
    runtime = MusicPlaybackRuntime(lambda _timeout: Connection(responses, calls))
    action = PrivateMusicCatalogAction(
        request=catalog_request(), token='private-token')
    result = runtime.search(action, deadline=time.monotonic() + 2)
    assert [item.uri for item in result.items] == ['spotify://track/right']
    assert calls[0][2]['command'] == 'music/search'
    assert 'private-token' not in repr(action)


class Backend:
    def __init__(self):
        self.target = MusicPlaybackRuntime(
            lambda _timeout: Connection([], []))._player(
                raw_player(), {'homepod-living'})

    def read_music_players(self, _authority, *, deadline, gate):
        assert gate() is True
        return MusicPlaybackReadback(players=[self.target])

    def execute_music_playback(self, _action, *, deadline, gate):
        assert gate() is True
        return MusicPlaybackWorkerResult(state='succeeded', target=self.target)

    def search_music_catalog(self, action, *, deadline, gate):
        assert gate() is True
        return MusicCatalogWorkerResult(items=[MusicCatalogItem(
            uri='spotify://track/result', name='Result', mediaType='track',
            providerInstanceId=action.request.providerInstanceId)])


def test_private_worker_ipc_supports_read_and_effect_without_secret_receipt():
    base = '/private/tmp' if Path('/private/tmp').is_dir() else '/tmp'
    with tempfile.TemporaryDirectory(prefix='mpc-', dir=base) as root:
        path = Path(root) / 'worker.sock'
        server = InstallationWorkerServer(
            path, Backend(), allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=1)
        server.start()
        try:
            client = InstallationWorkerClient(
                path, owner_uid=os.getuid(),
                peer_uid=lambda _connection: os.getuid(), timeout=1)
            authority = PrivateMusicPlaybackAuthority(
                installationId='b' * 32, token='private-token')
            observed = client.read_music_players(
                authority, deadline=time.monotonic() + 1, gate=lambda: True)
            result = client.execute_music_playback(
                PrivateMusicPlaybackAction(
                    request=request('pause'), token='private-token'),
                deadline=time.monotonic() + 1, gate=lambda: True)
            catalog = client.search_music_catalog(
                PrivateMusicCatalogAction(
                    request=catalog_request(), token='private-token'),
                deadline=time.monotonic() + 1, gate=lambda: True)
            assert observed.players[0].targetKind == 'homepod'
            assert result.target.playerId == 'homepod-living'
            assert catalog.items[0].uri == 'spotify://track/result'
            assert 'private-token' not in result.model_dump_json()
        finally:
            server.close()


def test_cancelled_runtime_makes_no_network_attempt():
    calls = []
    cancelled = threading.Event()
    cancelled.set()
    runtime = MusicPlaybackRuntime(lambda _timeout: Connection([], calls))
    try:
        runtime.execute(PrivateMusicPlaybackAction(
            request=request('pause'), token='private-token'),
            deadline=time.monotonic() + 1, cancelled=cancelled)
    except Exception as error:
        assert str(error) == 'music_playback_cancelled'
    else:
        raise AssertionError('cancelled playback was accepted')
    assert calls == []
