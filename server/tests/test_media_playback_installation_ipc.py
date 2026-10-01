import os
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

import pytest
from larenor_server.plugins.installation_ipc import (
    InstallationWorkerClient,
    InstallationWorkerServer,
)
from larenor_server.plugins.jellyfin_playback_executor import (
    JellyfinPlaybackExecutionError,
)
from larenor_server.plugins.media_playback_models import (
    PlaybackInfoReadback,
    MediaPlaybackReadback,
    MediaPlaybackTarget,
    MediaPlaybackWorkerResult,
    PrivateJellyfinPlaybackAction,
    PrivateJellyfinPlaybackAuthority,
    PrivateJellyfinPlaybackInfoAuthority,
    PrivateMediaPlaybackAction,
    PrivateMediaPlaybackAuthority,
)
from test_media_host_preflight import stack
from test_jellyfin_playback_runtime import USER, local_profile

TOKEN = 'k' * 32
INSTALLATION = 'a' * 32
ITEM = 'b' * 32


def private_authority():
    return PrivateJellyfinPlaybackAuthority(
        authority=PrivateMediaPlaybackAuthority(
            installationId=INSTALLATION, installationRevision=4,
            snapshotRevision=8, jellyfinServiceRevision=6,
            itemId=ITEM, mediaKey='movie:tmdb:603'),
        plan=stack(), apiKey=TOKEN)


def private_action():
    return PrivateJellyfinPlaybackAction(
        action=PrivateMediaPlaybackAction(
            requestId='d' * 32, intentId='e' * 32,
            installationId=INSTALLATION, installationRevision=4,
            snapshotRevision=8, jellyfinServiceRevision=6,
            itemId=ITEM, mediaKey='movie:tmdb:603',
            expectedPlaybackRevision=7, targetId='living-room',
            expectedTargetRevision=3, startSeconds=12),
        plan=stack(), apiKey=TOKEN)


def private_playback_info():
    return PrivateJellyfinPlaybackInfoAuthority(
        requestId='9' * 32,
        authority=PrivateMediaPlaybackAuthority(
            installationId=INSTALLATION, installationRevision=4,
            snapshotRevision=8, jellyfinServiceRevision=6,
            itemId=ITEM, mediaKey='movie:tmdb:603'),
        profile=local_profile(), expectedContentLength=2048,
        plan=stack(), apiKey=TOKEN, userId=USER)


class Backend:
    def __init__(self):
        self.calls = []
        self.execute_error = None

    def read_media_playback(self, authority, *, deadline, gate):
        assert deadline > time.monotonic() and gate() is True
        self.calls.append(('read', authority))
        return MediaPlaybackReadback(
            playbackRevision=7,
            targets=[MediaPlaybackTarget(
                targetId='living-room', targetRevision=3,
                name='Living room', available=True,
                currentItemId=None, positionSeconds=0)])

    def execute_media_playback(self, action, *, deadline, gate):
        assert deadline > time.monotonic() and gate() is True
        self.calls.append(('execute', action))
        if self.execute_error is not None:
            raise self.execute_error
        return MediaPlaybackWorkerResult(
            state='succeeded', playbackRevision=8,
            target=MediaPlaybackTarget(
                targetId='living-room', targetRevision=4,
                name='Living room', available=True,
                currentItemId=ITEM, positionSeconds=12))

    def read_playback_info(self, authority, *, deadline, gate):
        assert deadline > time.monotonic() and gate() is True
        self.calls.append(('playback_info', authority))
        return PlaybackInfoReadback(
            itemId=ITEM, profileDigest='1' * 64,
            assurance='provider_observed_for_client_reported_profile',
            originalByteOutcome='direct_play_supported',
            playMethod='direct_play',
            source={
                'container': 'mkv', 'bitrate': 25_000_000,
                'videoCodecs': ['hevc'], 'audioCodecs': ['eac3'],
                'videoRanges': ['HDR10'],
            },
            transcoding=None, reason='available')


@contextmanager
def running():
    with tempfile.TemporaryDirectory(
            prefix='lmp-',
            dir='/private/tmp' if Path('/private/tmp').is_dir() else '/tmp') as root:
        path = Path(root) / 'worker.sock'
        backend = Backend()
        server = InstallationWorkerServer(
            path, backend, allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid())
        server.start()
        try:
            yield backend, InstallationWorkerClient(
                path, owner_uid=os.getuid(),
                peer_uid=lambda _connection: os.getuid(), timeout=.5)
        finally:
            server.close()


def test_private_playback_authority_and_effect_roundtrip_without_secret_repr():
    authority, action = private_authority(), private_action()
    with running() as (backend, client):
        readback = client.read_media_playback(
            authority, deadline=time.monotonic() + .4, gate=lambda: True)
        result = client.execute_media_playback(
            action, deadline=time.monotonic() + .4, gate=lambda: True)

    assert readback.playbackRevision == 7
    assert result.playbackRevision == 8
    assert [call[0] for call in backend.calls] == ['read', 'execute']
    assert TOKEN not in repr(authority) + repr(action) + repr(backend.calls)


def test_private_playback_info_roundtrips_without_provider_identity_or_secret():
    authority = private_playback_info()
    with running() as (backend, client):
        result = client.read_playback_info(
            authority, deadline=time.monotonic() + .4, gate=lambda: True)

    assert result.originalByteOutcome == 'direct_play_supported'
    assert [call[0] for call in backend.calls] == ['playback_info']
    public = result.model_dump(mode='json')
    assert set(public) == {
        'schemaVersion', 'itemId', 'profileDigest', 'assurance',
        'originalByteOutcome', 'playMethod', 'source', 'transcoding',
        'reason'}
    assert TOKEN not in repr(authority) + repr(backend.calls) + repr(result)


def test_pre_effect_failure_keeps_typed_no_effect_classification_over_ipc():
    with running() as (backend, client):
        backend.execute_error = JellyfinPlaybackExecutionError(
            'jellyfin_playback_authority_changed', uncertain_effect=False)

        with pytest.raises(
                JellyfinPlaybackExecutionError,
                match='^jellyfin_playback_authority_changed$') as raised:
            client.execute_media_playback(
                private_action(), deadline=time.monotonic() + .4,
                gate=lambda: True)

    assert raised.value.uncertain_effect is False
    assert [call[0] for call in backend.calls] == ['execute']


def test_pre_effect_resource_failure_keeps_no_effect_classification_over_ipc():
    with running() as (backend, client):
        backend.execute_error = JellyfinPlaybackExecutionError(
            'jellyfin_playback_resources_unavailable', uncertain_effect=False)

        with pytest.raises(
                JellyfinPlaybackExecutionError,
                match='^jellyfin_playback_resources_unavailable$') as raised:
            client.execute_media_playback(
                private_action(), deadline=time.monotonic() + .4,
                gate=lambda: True)

    assert raised.value.uncertain_effect is False
    assert [call[0] for call in backend.calls] == ['execute']
