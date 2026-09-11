import json

import pytest
from pydantic import ValidationError

from larenor_server.plugins.media_archive_health import build_media_archive_health
from larenor_server.plugins.media_archive_health_models import (
    ArrArchiveItem,
    ArrArchiveSnapshot,
    JellyfinArchiveItem,
    JellyfinArchiveSnapshot,
    MediaArchiveObservation,
    QbittorrentArchiveItem,
    QbittorrentArchiveSnapshot,
)


INSTALLATION = '1' * 32


def binding(service, revision=7, state='verified', observed_at=1_788_609_600):
    return {
        'serviceId': service,
        'serviceRecordId': {
            'jellyfin': '2', 'sonarr': '3', 'radarr': '4', 'qbittorrent': '5'
        }[service] * 32,
        'serviceRevision': revision,
        'installationId': INSTALLATION,
        'installationRevision': 11,
        'state': state,
        'observedAt': observed_at,
    }


def observation(**changes):
    value = {
        'jellyfin': JellyfinArchiveSnapshot(
            **binding('jellyfin'),
            items=[
                JellyfinArchiveItem(
                    itemId='a' * 32, mediaKey='movie:tmdb:603',
                    title='The Matrix', mediaKind='movie', sizeBytes=8_000,
                    integrity='playable'),
                JellyfinArchiveItem(
                    itemId='b' * 32, mediaKey='episode:tvdb:101:1:2',
                    title='Pilot', mediaKind='episode', sizeBytes=2_000,
                    integrity='corrupt'),
            ],
        ),
        'sonarr': ArrArchiveSnapshot(
            **binding('sonarr'),
            items=[ArrArchiveItem(
                mediaKey='episode:tvdb:101:1:3', title='Second episode',
                mediaKind='episode', monitored=True, state='missing')],
        ),
        'radarr': ArrArchiveSnapshot(
            **binding('radarr'),
            items=[ArrArchiveItem(
                mediaKey='movie:tmdb:603', title='The Matrix',
                mediaKind='movie', monitored=True, state='available')],
        ),
        'qbittorrent': QbittorrentArchiveSnapshot(
            **binding('qbittorrent'),
            items=[
                QbittorrentArchiveItem(
                    torrentId='c' * 40, mediaKey='movie:tmdb:603',
                    title='The Matrix download', contentBytes=4_000,
                    state='complete', importedConfirmed=True,
                    retentionPolicySatisfied=True),
                QbittorrentArchiveItem(
                    torrentId='d' * 40, mediaKey='episode:tvdb:101:1:4',
                    title='Failed episode download', contentBytes=1_000,
                    state='error', importedConfirmed=False,
                    retentionPolicySatisfied=False),
            ],
        ),
    }
    value.update(changes)
    return MediaArchiveObservation(**value)


def test_combines_verified_sources_into_secret_free_health_and_review_candidates():
    result = build_media_archive_health(observation(), now=1_788_609_610)

    assert result.state == 'attention'
    assert result.sourceRevisions == {
        'jellyfin': 7, 'sonarr': 7, 'radarr': 7, 'qbittorrent': 7,
    }
    assert result.counts.model_dump() == {
        'missing': 1, 'broken': 1, 'failedDownloads': 1,
        'savingCandidates': 1, 'potentialSavingBytes': 4_000,
    }
    assert [issue.code for issue in result.issues] == [
        'corrupt_media', 'missing_media', 'download_error',
    ]
    assert result.suggestions[0].model_dump() == {
        'code': 'review_retained_download',
        'torrentId': 'c' * 40,
        'mediaKey': 'movie:tmdb:603',
        'title': 'The Matrix download',
        'potentialBytes': 4_000,
        'evidence': [
            'download_complete', 'import_verified',
            'retention_policy_satisfied',
        ],
        'cleanupAvailable': False,
    }
    wire = json.dumps(result.model_dump(mode='json'))
    assert all(word not in wire.lower() for word in (
        'token', 'password', 'cookie', 'endpoint', '/media/',
    ))


def test_unavailable_or_stale_source_is_explicit_and_suppresses_savings():
    offline = QbittorrentArchiveSnapshot(
        **binding('qbittorrent', state='unavailable'), items=[])
    unavailable = build_media_archive_health(
        observation(qbittorrent=offline), now=1_788_609_610)
    assert unavailable.state == 'incomplete'
    assert unavailable.sourceStates['qbittorrent'] == 'unavailable'
    assert unavailable.suggestions == []
    assert unavailable.counts.potentialSavingBytes == 0

    stale = build_media_archive_health(observation(), now=1_788_610_000)
    assert stale.state == 'incomplete'
    assert set(stale.sourceStates.values()) == {'stale'}
    assert stale.suggestions == []


def test_unmonitored_missing_and_unproven_download_never_become_actions():
    sonarr = ArrArchiveSnapshot(
        **binding('sonarr'),
        items=[ArrArchiveItem(
            mediaKey='episode:tvdb:101:1:3', title='Ignored episode',
            mediaKind='episode', monitored=False, state='missing')],
    )
    qbt = QbittorrentArchiveSnapshot(
        **binding('qbittorrent'),
        items=[QbittorrentArchiveItem(
            torrentId='e' * 40, mediaKey='movie:tmdb:603',
            title='Still seeding', contentBytes=99_000, state='complete',
            importedConfirmed=True, retentionPolicySatisfied=False)],
    )
    result = build_media_archive_health(
        observation(sonarr=sonarr, qbittorrent=qbt), now=1_788_609_610)
    assert result.suggestions == []
    assert all(issue.code != 'missing_media' for issue in result.issues)
    assert result.cleanupAvailable is False


@pytest.mark.parametrize('change', [
    {'token': 'secret'},
    {'items': [{'itemId': 'a' * 32, 'mediaKey': 'movie:tmdb:603',
                'title': 'Movie', 'mediaKind': 'movie', 'sizeBytes': 1,
                'integrity': 'playable', 'path': '/media/private'}]},
])
def test_source_contract_rejects_secret_or_path_shaped_fields(change):
    raw = {**binding('jellyfin'), 'items': []}
    raw.update(change)
    with pytest.raises(ValidationError):
        JellyfinArchiveSnapshot.model_validate(raw)


def test_duplicate_ids_cross_source_revision_or_future_observation_fail_closed():
    duplicate = JellyfinArchiveItem(
        itemId='a' * 32, mediaKey='movie:tmdb:603', title='Duplicate',
        mediaKind='movie', sizeBytes=1, integrity='playable')
    with pytest.raises(ValidationError):
        JellyfinArchiveSnapshot(
            **binding('jellyfin'), items=[duplicate, duplicate])

    changed = ArrArchiveSnapshot(
        **binding('sonarr', revision=8), items=[])
    with pytest.raises(ValueError, match='archive_authority_changed'):
        build_media_archive_health(
            observation(sonarr=changed), now=1_788_609_610)

    with pytest.raises(ValueError, match='archive_observation_invalid'):
        build_media_archive_health(observation(), now=1_788_609_590)


def test_empty_verified_archive_is_healthy_and_never_offers_cleanup():
    result = build_media_archive_health(MediaArchiveObservation(
        jellyfin=JellyfinArchiveSnapshot(**binding('jellyfin'), items=[]),
        sonarr=ArrArchiveSnapshot(**binding('sonarr'), items=[]),
        radarr=ArrArchiveSnapshot(**binding('radarr'), items=[]),
        qbittorrent=QbittorrentArchiveSnapshot(
            **binding('qbittorrent'), items=[]),
    ), now=1_788_609_610)
    assert result.state == 'healthy'
    assert result.issues == [] and result.suggestions == []
    assert result.cleanupAvailable is False
