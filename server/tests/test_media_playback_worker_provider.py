from dataclasses import dataclass
import time

import pytest

from larenor_server.plugins.media_playback import MediaPlaybackWorkerProvider
from larenor_server.plugins.media_playback_models import (
    MediaPlaybackReadback,
    MediaPlaybackTarget,
    MediaPlaybackWorkerResult,
    PrivateMediaPlaybackAction,
    PrivateMediaPlaybackAuthority,
)
from test_media_host_preflight import stack


@dataclass(frozen=True)
class Private:
    plan: object
    api_key: str
    bootstrap_revision: int


class Bootstraps:
    def __init__(self):
        self.revision = 3

    def playback_private(self, _installation_id, _revision):
        return Private(stack(), 'k' * 32, self.revision)


class Backend:
    def __init__(self, bootstraps):
        self.bootstraps = bootstraps

    @staticmethod
    def read_media_playback(_authority, *, deadline, gate):
        assert deadline > time.monotonic() and gate() is True
        return MediaPlaybackReadback(
            playbackRevision=7,
            targets=[MediaPlaybackTarget(
                targetId='living-room', targetRevision=3,
                name='Living room', available=True,
                currentItemId=None, positionSeconds=0)])

    def execute_media_playback(self, action, *, deadline, gate):
        assert deadline > time.monotonic() and gate() is True
        self.bootstraps.revision += 1
        return MediaPlaybackWorkerResult(
            state='succeeded', playbackRevision=8,
            target=MediaPlaybackTarget(
                targetId=action.action.targetId, targetRevision=4,
                name='Living room', available=True,
                currentItemId=action.action.itemId,
                positionSeconds=action.action.startSeconds))


def authority():
    return PrivateMediaPlaybackAuthority(
        installationId='a' * 32, installationRevision=4,
        snapshotRevision=8, jellyfinServiceRevision=6,
        itemId='b' * 32, mediaKey='movie:tmdb:603')


def action():
    return PrivateMediaPlaybackAction(
        requestId='c' * 32, intentId='d' * 32,
        installationId='a' * 32, installationRevision=4,
        snapshotRevision=8, jellyfinServiceRevision=6,
        itemId='b' * 32, mediaKey='movie:tmdb:603',
        expectedPlaybackRevision=7, targetId='living-room',
        expectedTargetRevision=3, startSeconds=12)


def test_provider_retains_exact_bootstrap_before_and_after_worker_read():
    bootstraps = Bootstraps()
    provider = MediaPlaybackWorkerProvider(Backend(bootstraps), bootstraps)

    result = provider.read_media_playback(
        authority(), deadline=time.monotonic() + 1, gate=lambda: True)

    assert result.playbackRevision == 7
    assert 'k' * 32 not in repr(provider) + repr(result)


def test_bootstrap_revision_change_after_effect_never_returns_success():
    bootstraps = Bootstraps()
    provider = MediaPlaybackWorkerProvider(Backend(bootstraps), bootstraps)

    with pytest.raises(ValueError, match='media_playback_authority_changed'):
        provider.execute_media_playback(
            action(), deadline=time.monotonic() + 1, gate=lambda: True)
