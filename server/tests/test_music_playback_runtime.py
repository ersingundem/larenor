import json
import os
from pathlib import Path
import tempfile
import threading
import time

from larenor_server.plugins.installation_ipc import (
    InstallationWorkerClient, InstallationWorkerServer,
)
from larenor_server.plugins.music_playback_models import (
    MusicPlaybackCommandRequest, MusicPlaybackReadback,
    MusicPlaybackWorkerResult, PrivateMusicPlaybackAction,
    PrivateMusicPlaybackAuthority,
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
        request = self.calls[-1][2]
        return Response({'message_id': request['message_id'],
                         'result': self.responses.pop(0)})

    def close(self):
        pass


def raw_player(identifier='homepod-living', *, group=None):
    return {
        'player_id': identifier, 'provider': 'airplay--main',
        'name': 'Living HomePod', 'available': True, 'enabled': True,
        'playback_state': 'paused', 'volume_level': 32,
        'volume_muted': False, 'group_members': group or [],
        'active_source': identifier, 'supported_features': [
            'pause', 'next_previous'], 'volume_control': 'native',
        'mute_control': 'native',
        'device_info': {'manufacturer': 'Apple', 'model': 'HomePod mini'},
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


def test_queue_add_is_one_explicit_effect_with_pre_and_post_readback():
    calls = []
    responses = [raw_player(), [{'queue_id': 'homepod-living'}], None,
                 raw_player()]
    runtime = MusicPlaybackRuntime(lambda _timeout: Connection(responses, calls))
    action = PrivateMusicPlaybackAction(
        request=request(), token='private-token')
    result = runtime.execute(action, deadline=time.monotonic() + 2)
    assert result.state == 'succeeded'
    assert [call[2]['command'] for call in calls] == [
        'players/get', 'player_queues/all', 'player_queues/play_media',
        'players/get']
    effect = calls[2][2]['args']
    assert effect == {'queue_id': 'homepod-living',
                      'media': ['spotify://track/fixture'],
                      'option': 'add', 'radio_mode': False}
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
            assert observed.players[0].targetKind == 'homepod'
            assert result.target.playerId == 'homepod-living'
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
