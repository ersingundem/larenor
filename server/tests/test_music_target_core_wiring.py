import json
import os
from pathlib import Path
import socket
import stat
import threading
import time

import pytest

from larenor_server.config import Settings
from larenor_server.errors import StartupError
from larenor_server.plugins.music_target_health import (
    MusicTargetWorkerHealthError, MusicTargetWorkerHealthGuard,
)
from larenor_server.plugins.music_target_worker_runtime import (
    AtomicMusicTargetWorkerHealth,
)


def private(path):
    path.mkdir(mode=0o700)
    path.chmod(0o700)
    return path


@pytest.mark.parametrize('configured', [
    {'music_playback_worker_socket': Path('/run/larenor/music.sock')},
    {'music_playback_lease_dir': Path('/run/larenor/leases')},
    {'music_playback_worker_health': Path('/run/larenor/health.json')},
])
def test_music_worker_settings_are_all_or_nothing(tmp_path, configured):
    with pytest.raises(ValueError, match='invalid_worker_configuration'):
        Settings(tmp_path / 'data', tmp_path / 'key', **configured)


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
            with client:
                pass

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return server, stop, thread


def test_core_binds_live_private_socket_to_exact_health_session(tmp_path):
    root = private(tmp_path / 'run')
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


def test_socket_inode_uid_or_health_state_change_fails_closed(tmp_path):
    root = private(tmp_path / 'run')
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


def test_health_receipt_is_private_and_never_contains_endpoint_or_secret(tmp_path):
    root = private(tmp_path / 'run')
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
