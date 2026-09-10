"""UID-bound worker IPC for Music Assistant first-run bootstrap."""

import os
from pathlib import Path
import tempfile
import time

import pytest

from larenor_server.plugins.installation_ipc import (
    InstallationWorkerClient,
    InstallationWorkerServer,
)
from larenor_server.plugins.music_assistant_bootstrap_models import (
    PrivateMusicAssistantBootstrap,
)
from larenor_server.plugins.music_assistant_bootstrap_runtime import (
    MusicAssistantBootstrapRuntimeError,
)
from larenor_server.plugins.music_assistant_core_models import (
    AuthenticatedMusicAssistantReadback,
)


def private():
    return PrivateMusicAssistantBootstrap(
        installationId='a' * 32, credential='S' * 48)


class Backend:
    def __init__(self, failure=None):
        self.failure = failure
        self.seen = None

    def bootstrap_music_assistant(self, installation_id, username, credential,
                                  *, deadline, gate):
        assert gate() is True and time.monotonic() < deadline
        self.seen = (installation_id, username, credential)
        if self.failure is not None:
            raise self.failure
        return AuthenticatedMusicAssistantReadback(
            token='private-long-token', serverId='mass-fixture',
            serverVersion='2.10.2', schemaVersion=65)


def roundtrip(backend, callback):
    base = '/private/tmp' if Path('/private/tmp').is_dir() else '/tmp'
    with tempfile.TemporaryDirectory(prefix='mab-', dir=base) as root:
        path = Path(root) / 'install.sock'
        server = InstallationWorkerServer(
            path, backend, allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=1)
        server.start()
        try:
            client = InstallationWorkerClient(
                path, owner_uid=os.getuid(),
                peer_uid=lambda _connection: os.getuid(), timeout=1)
            return callback(client)
        finally:
            server.close()


def test_private_bootstrap_roundtrip_returns_only_strict_readback():
    backend = Backend()
    result = roundtrip(backend, lambda client: client.bootstrap_music_assistant(
        private(), deadline=time.monotonic() + 1, gate=lambda: True))

    assert result == AuthenticatedMusicAssistantReadback(
        token='private-long-token', serverId='mass-fixture',
        serverVersion='2.10.2', schemaVersion=65)
    assert backend.seen == ('a' * 32, 'larenor-core', 'S' * 48)
    assert 'private-long-token' not in repr(result)
    assert 'S' * 48 not in repr(private())


def test_static_uncertain_worker_failure_survives_ipc_without_secret():
    failure = MusicAssistantBootstrapRuntimeError(
        'music_assistant_bootstrap_readback_changed', uncertain_effect=True)
    backend = Backend(failure)
    with pytest.raises(
            MusicAssistantBootstrapRuntimeError,
            match='^music_assistant_bootstrap_readback_changed$') as raised:
        roundtrip(backend, lambda client: client.bootstrap_music_assistant(
            private(), deadline=time.monotonic() + 1, gate=lambda: True))
    assert raised.value.uncertain_effect is True
    assert 'S' * 48 not in repr(raised.value)


def test_invalid_or_expired_request_never_reaches_worker():
    backend = Backend()
    base = private()
    with pytest.raises(Exception):
        roundtrip(backend, lambda client: client.bootstrap_music_assistant(
            base, deadline=time.monotonic() - 1, gate=lambda: True))
    assert backend.seen is None

    with pytest.raises(Exception):
        PrivateMusicAssistantBootstrap(
            installationId='short', credential='S' * 48)
