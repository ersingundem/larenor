import json
import os
from pathlib import Path
import stat
import threading
import time

import pytest

from larenor_server.plugins.music_playback_models import (
    MusicPlaybackCommandRequest, PrivateMusicAssistantServiceBinding,
    PrivateMusicPlaybackAction,
)
from larenor_server.plugins.music_playback_runtime import MusicPlaybackRuntime
from larenor_server.plugins.music_target_effect_models import (
    MusicTargetEffectEnvelope,
)
from larenor_server.plugins.music_target_effect_runtime import (
    MusicTargetEffectRuntime,
)
from larenor_server.plugins.music_target_lease import (
    MusicTargetCredentialLeaseError, MusicTargetCredentialLeaseStore,
)
from larenor_server.plugins.music_target_leased_client import (
    LeasedMusicTargetWorkerClient,
)
from larenor_server.plugins.music_target_transport import (
    MusicAssistantHTTPConnection, MusicTargetTransportError,
)
from larenor_server.plugins.music_target_worker_runtime import (
    AtomicMusicTargetWorkerHealth, BoundedMusicTargetWorkerSupervisor,
    MusicTargetWorkerConfigurationError, check_configuration,
)


def effect(operation='pause', **changes):
    values = {
        'executionId': '1' * 32, 'commandId': '2' * 32,
        'requestId': '3' * 32, 'previewId': '4' * 32,
        'installationId': '5' * 32, 'installationRevision': 6,
        'coreRevision': 7, 'playerRevision': 8,
        'providerRevisions': [{
            'id': '6' * 32, 'revision': 9,
            'providerDomain': 'spotify'}],
        'target': {
            'id': 'homepod-living', 'name': 'Living HomePod',
            'provider': 'airplay--main', 'transport': 'airplay',
            'kind': 'device', 'homePod': True, 'available': True,
            'enabled': True, 'playbackState': 'paused', 'volumeLevel': 30,
            'muted': False, 'groupMemberIds': [],
            'queueId': 'homepod-living',
            'capabilities': [
                'play', 'pause', 'stop', 'seek', 'volume_set', 'queue'],
        },
        'operation': operation, 'volumeLevel': None, 'muted': None,
        'seekPosition': 19 if operation == 'seek' else None,
        'mediaUris': [],
    }
    values.update(changes)
    return MusicTargetEffectEnvelope.model_validate(values)


def binding(endpoint='http://127.0.0.1:8095'):
    return PrivateMusicAssistantServiceBinding(
        installationId='5' * 32, installationRevision=6, coreRevision=7,
        endpoint=endpoint, pinnedPeer='127.0.0.1', serverId='mass-fixture',
        serverVersion='2.8.0', schemaVersion=29,
        token='private-token-cookie')


def private_root(tmp_path):
    root = tmp_path / 'leases'
    root.mkdir(mode=0o700)
    root.chmod(0o700)
    return root


def test_credential_lease_is_encrypted_exact_short_lived_and_one_use(tmp_path):
    now = [1788609600.0]
    root = private_root(tmp_path)
    store = MusicTargetCredentialLeaseStore(
        root, b'k' * 32, clock=lambda: now[0])
    action = effect()
    store.issue(action, binding(), expires_at=now[0] + 4)
    path = root / (action.executionId + '.lease')
    raw = path.read_bytes()
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert b'private-token-cookie' not in raw
    assert b'127.0.0.1' not in raw
    observed = store.consume(action)
    assert observed.token == 'private-token-cookie'
    assert not path.exists()
    with pytest.raises(MusicTargetCredentialLeaseError):
        store.consume(action)


def test_credential_lease_rejects_expiry_clock_rollback_and_revision_drift(tmp_path):
    now = [100.0]
    store = MusicTargetCredentialLeaseStore(
        private_root(tmp_path), b'z' * 32, clock=lambda: now[0])
    action = effect()
    store.issue(action, binding(), expires_at=104.0)
    with pytest.raises(MusicTargetCredentialLeaseError):
        store.consume(effect(playerRevision=99))
    now[0] = 90.0
    with pytest.raises(MusicTargetCredentialLeaseError):
        store.consume(action)
    now[0] = 105.0
    with pytest.raises(MusicTargetCredentialLeaseError):
        store.consume(action)


class Socket:
    family = 2

    def __init__(self, peer):
        self.peer = peer

    def getpeername(self):
        return self.peer


class HTTP:
    def __init__(self, peer=('127.0.0.1', 8095)):
        self.sock = Socket(peer)
        self.requests = []

    def connect(self):
        pass

    def request(self, method, path, *, body, headers):
        self.requests.append((method, path, body, headers))

    def getresponse(self):
        return type('Response', (), {
            'getheaders': lambda _self: [('Content-Type', 'application/json')],
        })()

    def close(self):
        pass


def test_transport_pins_numeric_private_peer_and_rejects_redirect_or_rebind():
    created = []

    def factory(host, port, *, timeout):
        created.append((host, port, timeout))
        return HTTP()

    connection = MusicAssistantHTTPConnection(
        'http://127.0.0.1:8095', '127.0.0.1', .5,
        http_factory=factory)
    connection.request('POST', '/api', body=b'{}', headers={})
    connection.getresponse()
    assert created == [('127.0.0.1', 8095, .5)]
    changed = MusicAssistantHTTPConnection(
        'http://127.0.0.1:8095', '127.0.0.1', .5,
        http_factory=lambda *_args, **_kwargs: HTTP(('127.0.0.2', 8095)))
    with pytest.raises(MusicTargetTransportError):
        changed.request('POST', '/api', body=b'{}', headers={})


@pytest.mark.parametrize(('operation', 'position', 'expected'), [
    ('resume', None, ('players/cmd/resume', {'player_id': 'homepod-living'})),
    ('seek', 19, ('players/cmd/seek', {
        'player_id': 'homepod-living', 'position': 19})),
])
def test_runtime_uses_official_allowlisted_resume_and_seek_commands(
        operation, position, expected):
    from test_music_playback_runtime import Connection, raw_player
    player = raw_player()
    player['supported_features'].append('seek')
    calls = []
    responses = [{
        'server_id': 'mass-fixture', 'server_version': '2.8.0',
        'schema_version': 29}, player, [{'queue_id': 'homepod-living'}],
        None, player]
    runtime = MusicPlaybackRuntime(lambda _timeout: Connection(responses, calls))
    request = MusicPlaybackCommandRequest(
        requestId='1' * 32, installationId='5' * 32,
        expectedInstallationRevision=6, expectedCoreRevision=7,
        expectedPlayerRevision=8, targetId='homepod-living',
        expectedProvider='airplay--main', expectedTargetKind='homepod',
        expectedQueueId='homepod-living', expectedGroupMembers=[],
        operation=operation, seekPosition=position)
    result = runtime.execute(
        PrivateMusicPlaybackAction(request=request, token=binding().token),
        deadline=time.monotonic() + 2, binding=binding())
    assert result.state == 'succeeded'
    assert (calls[3][2]['command'], calls[3][2]['args']) == expected
    assert [call[2]['command'] for call in calls[:3]] == [
        'info', 'players/get', 'player_queues/all']
    assert calls[-1][2]['command'] == 'players/get'


class Playback:
    def __init__(self):
        self.calls = []

    def execute(self, action, *, deadline, cancelled=None, binding=None):
        assert binding is not None
        self.calls.append(action)
        target = action.request
        from larenor_server.plugins.music_playback_models import (
            MusicPlaybackWorkerResult, VerifiedMusicPlayer,
        )
        return MusicPlaybackWorkerResult(state='succeeded', target=VerifiedMusicPlayer(
            playerId=target.targetId, name='Living HomePod',
            provider=target.expectedProvider, targetKind='homepod',
            available=True, enabled=True, playbackState='playing',
            volumeLevel=30, muted=False, groupMembers=[],
            queueId=target.expectedQueueId,
            capabilities=['play', 'pause', 'stop', 'seek', 'volume_set', 'queue']))


def test_worker_consumes_lease_and_returns_only_authenticated_readback(tmp_path):
    store = MusicTargetCredentialLeaseStore(
        private_root(tmp_path), b'x' * 32, clock=time.time)
    action = effect('resume', seekPosition=None)
    store.issue(action, binding(), expires_at=time.time() + 4)
    playback = Playback()
    result = MusicTargetEffectRuntime(playback, store).execute(
        action, deadline=time.monotonic() + 2)
    assert result.state == 'succeeded'
    assert result.requestId == action.requestId
    assert playback.calls[0].request.operation == 'resume'
    assert 'private-token-cookie' not in result.model_dump_json()
    with pytest.raises(MusicTargetCredentialLeaseError):
        store.consume(action)


def test_core_issues_lease_without_adding_credentials_to_ipc_envelope(tmp_path):
    store = MusicTargetCredentialLeaseStore(
        private_root(tmp_path), b'w' * 32, clock=time.time)
    action = effect()
    seen = []

    class Delegate:
        def execute_music_target_effect(self, envelope, *, deadline, gate):
            seen.append(envelope.model_dump(mode='json'))
            private = store.consume(envelope)
            assert private.token == 'private-token-cookie'
            from larenor_server.plugins.music_target_effect_models import (
                MusicTargetEffectResult,
            )
            return MusicTargetEffectResult(
                state='succeeded', executionId=envelope.executionId,
                commandId=envelope.commandId, requestId=envelope.requestId,
                target=envelope.target)

    client = LeasedMusicTargetWorkerClient(
        Delegate(), store, lambda _action: binding(), clock=time.time)
    result = client.execute_music_target_effect(
        action, deadline=time.monotonic() + 2, gate=lambda: True)
    assert result.state == 'succeeded'
    wire = json.dumps(seen)
    assert all(value not in wire.lower() for value in (
        'private-token-cookie', 'token', 'cookie', 'endpoint', '127.0.0.1'))


class Stop:
    def __init__(self):
        self.value = False
        self.waits = []

    def is_set(self):
        return self.value

    def wait(self, delay=None):
        self.waits.append(delay)
        return self.value


class Session:
    def __init__(self, events, fail=False):
        self.events, self.fail = events, fail

    def start(self):
        self.events.append('start')
        if self.fail:
            raise RuntimeError('private-token-cookie')

    def wait(self, stop):
        self.events.append('wait')
        stop.value = True

    def close(self):
        self.events.append('close')


def test_supervisor_health_is_secret_free_and_restart_is_bounded(tmp_path):
    root = private_root(tmp_path)
    health = AtomicMusicTargetWorkerHealth(root / 'health.json')
    events = []
    sessions = iter([Session(events, True), Session(events)])
    supervisor = BoundedMusicTargetWorkerSupervisor(
        lambda: next(sessions), health, max_restarts=1,
        initial_backoff=.01, maximum_backoff=.01)
    stop = Stop()
    assert supervisor.run(stop) == 0
    value = json.loads((root / 'health.json').read_text())
    assert value['state'] == 'stopped'
    assert value['effectAvailable'] is False
    assert value['installAvailable'] is False
    assert 'token' not in json.dumps(value).lower()
    assert events == ['start', 'close', 'start', 'wait', 'close']


def test_check_config_is_offline_and_default_effect_unavailable(tmp_path, monkeypatch):
    root = private_root(tmp_path)
    key = tmp_path / 'lease.key'
    key.write_bytes(b'q' * 32)
    key.chmod(0o600)
    monkeypatch.setattr(
        'socket.create_connection',
        lambda *_args, **_kwargs: pytest.fail('check config used network'))
    result = check_configuration(
        socket_path=root / 'worker.sock', lease_dir=root,
        lease_key_file=key, api_uid=os.getuid())
    assert result == {'effectAvailable': False, 'installAvailable': False}
    key.chmod(0o644)
    with pytest.raises(MusicTargetWorkerConfigurationError):
        check_configuration(
            socket_path=root / 'worker.sock', lease_dir=root,
            lease_key_file=key, api_uid=os.getuid())
