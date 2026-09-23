from contextlib import contextmanager
import os
from pathlib import Path
import tempfile
import time

from larenor_server.plugins.installation_ipc import (
    InstallationWorkerClient,
    InstallationWorkerServer,
)
from larenor_server.plugins.media_playback_models import (
    MediaPlaybackReadback,
    MediaPlaybackTarget,
    MediaPlaybackWorkerResult,
    PrivateJellyfinPlaybackAction,
    PrivateJellyfinPlaybackAuthority,
    PrivateMediaPlaybackAction,
    PrivateMediaPlaybackAuthority,
)
from test_media_host_preflight import stack


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


class Backend:
    def __init__(self):
        self.calls = []

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
        return MediaPlaybackWorkerResult(
            state='succeeded', playbackRevision=8,
            target=MediaPlaybackTarget(
                targetId='living-room', targetRevision=4,
                name='Living room', available=True,
                currentItemId=ITEM, positionSeconds=12))


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
