import json
import os
from pathlib import Path
import socket
import stat
import tempfile
import threading
import time
from dataclasses import replace

import pytest

from larenor_server.config import Settings
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from larenor_server.plugins.music_target_health import (
    MusicTargetWorkerHealthError, MusicTargetWorkerHealthGuard,
)
from larenor_server.plugins.music_target_lease import (
    MusicTargetCredentialLeaseStore,
)
from larenor_server.plugins.music_target_effect_models import (
    MusicTargetEffectResult,
)
from larenor_server.plugins.music_target_worker_runtime import (
    AtomicMusicTargetWorkerHealth,
)
from larenor_server.plugins.music_target_ipc import MusicTargetWorkerServer
from larenor_server.plugins.music_target_leased_client import (
    LeasedMusicTargetWorkerClient,
)
from conftest import auth, ready
from test_services import BASE as SERVICES_BASE, create as create_service
from test_music_playback import provider_ready
from test_music_target_worker_runtime_transport import effect
from larenor_server.plugins.music_assistant_core import managed_music_service_id


def private(path):
    path.mkdir(mode=0o700)
    path.chmod(0o700)
    return path


@pytest.fixture
def short_root():
    with tempfile.TemporaryDirectory(prefix='lmw-', dir='/private/tmp') as value:
        yield private(Path(value) / 'run')


@pytest.mark.parametrize('configured', [
    {'music_playback_worker_socket': Path('/run/larenor/music.sock')},
    {'music_playback_lease_dir': Path('/run/larenor/leases')},
    {'music_playback_worker_health': Path('/run/larenor/health.json')},
])
def test_music_worker_settings_are_all_or_nothing(tmp_path, configured, monkeypatch):
    names = {
        'music_playback_worker_socket': 'LARENOR_MUSIC_PLAYBACK_WORKER_SOCKET',
        'music_playback_lease_dir': 'LARENOR_MUSIC_PLAYBACK_LEASE_DIR',
        'music_playback_worker_health': 'LARENOR_MUSIC_PLAYBACK_WORKER_HEALTH',
    }
    key, value = next(iter(configured.items()))
    monkeypatch.setenv(names[key], str(value))
    with pytest.raises(StartupError, match='invalid_worker_configuration'):
        Settings.from_environment()


def listener(path):
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
    os.chmod(path, 0o600)
    server.listen(4)
    stop = threading.Event()

    def run():
        while not stop.is_set():
            server.settimeout(.05)
            try:
                client, _ = server.accept()
            except TimeoutError:
                continue
            except OSError:
                break
            with client:
                pass

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return server, stop, thread


def test_core_binds_live_private_socket_to_exact_health_session(short_root):
    root = short_root
    path = root / 'music.sock'
    server, stop, thread = listener(path)
    try:
        health = AtomicMusicTargetWorkerHealth(root / 'health.json')
        health.write('ready', 1, socket_path=path, session_id='a' * 32)
        guard = MusicTargetWorkerHealthGuard(
            path, root / 'health.json', owner_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=.2)
        binding = guard.bind()
        assert binding.sessionId == 'a' * 32
        assert binding.socketInode == path.stat().st_ino
        guard.check(binding)
        health.write('ready', 1, socket_path=path, session_id='b' * 32)
        with pytest.raises(MusicTargetWorkerHealthError):
            guard.check(binding)
    finally:
        stop.set()
        server.close()
        thread.join(.3)


def test_socket_inode_uid_or_health_state_change_fails_closed(short_root):
    root = short_root
    path = root / 'music.sock'
    server, stop, thread = listener(path)
    health = AtomicMusicTargetWorkerHealth(root / 'health.json')
    health.write('ready', 1, socket_path=path, session_id='c' * 32)
    guard = MusicTargetWorkerHealthGuard(
        path, root / 'health.json', owner_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(), timeout=.2)
    binding = guard.bind()
    stop.set()
    server.close()
    thread.join(.3)
    path.unlink()
    replacement, replacement_stop, replacement_thread = listener(path)
    try:
        with pytest.raises(MusicTargetWorkerHealthError):
            guard.check(binding)
        health.write('failed', 1)
        with pytest.raises(MusicTargetWorkerHealthError):
            guard.bind()
    finally:
        replacement_stop.set()
        replacement.close()
        replacement_thread.join(.3)


def test_health_receipt_is_private_and_never_contains_endpoint_or_secret(short_root):
    root = short_root
    path = root / 'music.sock'
    server, stop, thread = listener(path)
    try:
        target = root / 'health.json'
        AtomicMusicTargetWorkerHealth(target).write(
            'ready', 1, socket_path=path, session_id='d' * 32)
        value = json.loads(target.read_text())
        assert value['effectAvailable'] is True
        assert value['installAvailable'] is False
        assert value['socketUid'] == os.getuid()
        assert stat.S_IMODE(target.stat().st_mode) == 0o600
        assert all(word not in target.read_text().lower() for word in (
            'token', 'cookie', 'endpoint', 'authorization'))
    finally:
        stop.set()
        server.close()
        thread.join(.3)


def test_core_startup_attaches_only_to_live_verified_worker(
        server, short_root, monkeypatch):
    _, _, settings, _ = server
    path = short_root / 'music.sock'

    class Backend:
        def execute_music_target_effect(self, *_args, **_kwargs):
            raise AssertionError('startup dispatched an effect')

    worker = MusicTargetWorkerServer(
        path, Backend(), allowed_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(), timeout=.2)
    worker.start()
    try:
        health_path = short_root / 'health.json'
        AtomicMusicTargetWorkerHealth(health_path).write(
            'ready', 1, socket_path=path, session_id='e' * 32)
        leases = private(short_root / 'leases')
        monkeypatch.setattr(
            'larenor_server.plugins.music_target_health._peer_uid',
            lambda _connection: os.getuid())
        app = create_app(replace(
            settings, music_playback_worker_socket=path,
            music_playback_worker_uid=os.getuid(),
            music_playback_lease_dir=leases,
            music_playback_worker_health=health_path))
        assert type(app.state.core.music_target_authority.effect_backend) is (
            LeasedMusicTargetWorkerClient)
    finally:
        worker.close()


def test_worker_compose_bridge_has_no_public_worker_port_or_inline_secret():
    path = Path(__file__).parents[2] / 'deploy/larenor-server/music-worker.compose.yaml'
    config = json.loads(path.read_text())
    worker = config['services']['larenor-music-target-worker']
    assert 'ports' not in worker and 'expose' not in worker
    assert worker['network_mode'] == 'service:larenor-server'
    assert worker['read_only'] is True
    assert worker['cap_drop'] == ['ALL']
    assert worker['security_opt'] == ['no-new-privileges:true']
    assert worker['environment'] == {}
    assert any(volume['target'] == '/run/larenor' for volume in worker['volumes'])
    assert any(volume['target'] == '/secrets/vault.key'
               and volume['read_only'] is True for volume in worker['volumes'])
    assert config['x-larenor-core-environment'] == {
        'LARENOR_MUSIC_PLAYBACK_WORKER_SOCKET':
            '/run/larenor/music-target.sock',
        'LARENOR_MUSIC_PLAYBACK_WORKER_UID': '10001',
        'LARENOR_MUSIC_PLAYBACK_LEASE_DIR': '/run/larenor/leases',
        'LARENOR_MUSIC_PLAYBACK_WORKER_HEALTH':
            '/run/larenor/music-target-health.json',
    }


def test_music_service_egress_is_exact_revision_policy_and_ip_pinned(server):
    app, client, _, _ = server
    pair = ready(server)
    service = create_service(
        client, pair, name='Managed Music Assistant', kind='music_assistant',
        baseUrl='http://127.0.0.1:8095',
        credentials={'token': 'private-mass-token'})
    actor = app.state.core.auth.authenticate(pair['accessToken'])
    app.state.core.services.record_verification(
        actor, service['id'], 1, state='authenticated', version='2.8.0')
    response = client.put(
        f'{SERVICES_BASE}/{service["id"]}/outbound-policy',
        headers=auth(pair), json={
            'expectedRevision': 0, 'expectedServiceRevision': 1,
            'grants': [{
                'scheme': 'http', 'host': '127.0.0.1', 'port': 8095,
                'addresses': [{
                    'address': '127.0.0.1', 'network': 'loopback'}]}]})
    assert response.status_code == 200, response.text
    assert response.json()['policy']['component'] == 'music_assistant_playback'
    with app.state.core.db.connection() as connection:
        observed, policy, address, version = (
            app.state.core.component_egress.music_playback_binding(connection))
    assert (observed.id, observed.revision, policy.revision, address, version) == (
        service['id'], 1, 1, '127.0.0.1', '2.8.0')
    changed = client.patch(
        f'{SERVICES_BASE}/{service["id"]}', headers=auth(pair), json={
            'expectedRevision': 1, 'name': 'Changed Music Assistant',
            'baseUrl': 'http://127.0.0.1:8096',
            'credentials': {'token': 'changed-private-token'}})
    assert changed.status_code == 200
    with app.state.core.db.connection() as connection:
        with pytest.raises(Exception):
            app.state.core.component_egress.music_playback_binding(connection)


def test_authenticated_core_readback_auto_wires_secret_free_service_record(server):
    app, client, _, _ = server
    pair, setup, _readiness = provider_ready(server)
    service_id = managed_music_service_id(setup['installationId'])
    services = client.get(SERVICES_BASE, headers=auth(pair)).json()['services']
    managed = next(item for item in services if item['id'] == service_id)
    assert managed['kind'] == 'music_assistant'
    assert managed['baseUrl'] == 'http://127.0.0.1:8095'
    assert managed['credentialKeys'] == ['token']
    assert managed['verification']['state'] == 'authenticated'
    policy = client.get(
        f'{SERVICES_BASE}/{service_id}/outbound-policy',
        headers=auth(pair)).json()['policy']
    assert policy['component'] == 'music_assistant_playback'
    assert policy['grants'] == []
    with app.state.core.db.connection() as connection:
        dump = '\n'.join(connection.iterdump())
    assert 'synthetic-music-assistant-token-never-public' not in dump


def test_private_lease_binding_carries_exact_service_policy_and_ip(server):
    app, client, _, _ = server
    pair, setup, readiness = provider_ready(server)
    service_id = managed_music_service_id(setup['installationId'])
    granted = client.put(
        f'{SERVICES_BASE}/{service_id}/outbound-policy',
        headers=auth(pair), json={
            'expectedRevision': 0, 'expectedServiceRevision': 1,
            'grants': [{
                'scheme': 'http', 'host': '127.0.0.1', 'port': 8095,
                'addresses': [{
                    'address': '127.0.0.1', 'network': 'loopback'}]}]})
    assert granted.status_code == 200
    action = effect(
        installationId=setup['installationId'],
        installationRevision=setup['installationRevision'],
        coreRevision=readiness['revision'])
    private_binding = app.state.core.music_playback.effect_binding(action)
    assert (private_binding.serviceId, private_binding.serviceRevision,
            private_binding.egressPolicyRevision,
            private_binding.pinnedPeer) == (service_id, 1, 1, '127.0.0.1')
    assert 'synthetic-music-assistant-token-never-public' not in repr(
        private_binding)


def test_post_effect_health_change_is_unknown_boundary_and_never_retried(short_root):
    from test_music_target_worker_runtime_transport import binding
    action = effect()
    store = MusicTargetCredentialLeaseStore(
        private(short_root / 'leases'), b'h' * 32, clock=time.time)

    class Guard:
        calls = 0

        def check(self, _binding):
            self.calls += 1
            if self.calls == 3:
                raise MusicTargetWorkerHealthError(
                    'music_worker_health_unavailable')

    class Delegate:
        calls = 0

        def execute_music_target_effect(self, envelope, *, deadline, gate):
            self.calls += 1
            return MusicTargetEffectResult(
                state='succeeded', executionId=envelope.executionId,
                commandId=envelope.commandId, requestId=envelope.requestId,
                target=envelope.target)

    guard, delegate = Guard(), Delegate()
    client = LeasedMusicTargetWorkerClient(
        delegate, store, lambda _action: binding(), clock=time.time,
        health_guard=guard, health_binding=object())
    with pytest.raises(MusicTargetWorkerHealthError):
        client.execute_music_target_effect(
            action, deadline=time.monotonic() + 2, gate=lambda: True)
    assert delegate.calls == 1
    assert not (short_root / 'leases' / (action.executionId + '.lease')).exists()
