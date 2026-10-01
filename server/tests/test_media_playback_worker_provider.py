from dataclasses import dataclass
import time

import pytest

from larenor_server.plugins.media_playback import MediaPlaybackWorkerProvider
from larenor_server.plugins.media_playback_models import (
    MediaPlaybackReadback,
    MediaPlaybackTarget,
    MediaPlaybackWorkerResult,
    PlaybackInfoReadback,
    local_playback_profile_digest,
    PrivateMediaPlaybackAction,
    PrivateMediaPlaybackAuthority,
)
from test_media_host_preflight import stack


@dataclass(frozen=True)
class Private:
    plan: object
    api_key: str
    user_id: str
    bootstrap_revision: int


class Bootstraps:
    def __init__(self):
        self.revision = 3

    def playback_private(self, _installation_id, _revision):
        return Private(stack(), 'k' * 32, 'f' * 32, self.revision)


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

    @staticmethod
    def read_playback_info(authority, *, deadline, gate):
        assert deadline > time.monotonic() and gate() is True
        assert authority.userId == 'f' * 32
        return PlaybackInfoReadback(
            itemId=authority.authority.itemId,
            profileDigest=local_playback_profile_digest(authority.profile),
            assurance='provider_observed_for_client_reported_profile',
            originalByteOutcome='contract_unknown', playMethod='unknown',
            source=None, transcoding=None, reason='contract_unsupported')


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


def test_playback_info_binds_private_user_without_exposing_it():
    from test_jellyfin_playback_runtime import local_profile

    bootstraps = Bootstraps()
    provider = MediaPlaybackWorkerProvider(Backend(bootstraps), bootstraps)
    result = provider.read_playback_info(
        authority(), request_id='9' * 32, profile=local_profile(),
        expected_content_length=2048, deadline=time.monotonic() + 1,
        gate=lambda: True)

    assert result.reason == 'contract_unsupported'
    assert 'f' * 32 not in repr(result) + repr(provider)
