from larenor_server.plugins.media_archive_health import build_media_archive_health
from larenor_server.plugins.media_archive_health_models import (
    JellyfinArchiveItem,
    MediaArchiveTranscodeEvidence,
)
from test_media_archive_health import observation


def playable(identifier, size, *, transcode=None):
    return JellyfinArchiveItem(
        itemId=identifier * 32,
        mediaKey='movie:tmdb:603',
        title='The Matrix',
        mediaKind='movie',
        sizeBytes=size,
        integrity='playable',
        transcode=transcode,
    )


def test_builds_explainable_duplicate_transcode_and_retention_review_plan():
    transcode = MediaArchiveTranscodeEvidence(
        sourceCodec='h264', targetCodec='hevc', sourceBitrate=8_000_000,
        targetBitrate=4_000_000, durationSeconds=10,
        targetPlaybackVerified=True,
    )
    base = observation()
    jellyfin = base.jellyfin.model_copy(update={
        'items': [playable('a', 10_000_000, transcode=transcode),
                  playable('b', 4_000_000)],
        'transcodeEvidence': 'verified',
    })
    result = build_media_archive_health(
        base.model_copy(update={'jellyfin': jellyfin}), now=1_788_609_610)
    plan = result.savingsPlan
    assert plan.state == 'ready'
    assert [(item.kind, item.potentialBytes) for item in plan.candidates] == [
        ('duplicate', 4_000_000),
        ('retention', 4_000),
        ('transcode', 5_000_000),
    ]
    assert plan.laneStates == {
        'duplicate': 'verified', 'transcode': 'verified',
        'retention': 'verified',
    }
    assert plan.totalPotentialBytes == 9_004_000
    assert plan.actionAvailable is False and plan.truncated is False
    assert all(item.actionAvailable is False for item in plan.candidates)
    assert plan.candidates[0].evidence == [
        'same_media_identity', 'multiple_playable_files',
        'largest_copy_excluded',
    ]


def test_plan_suppresses_unproven_candidates_and_marks_lanes_partial():
    base = observation()
    unsupported = build_media_archive_health(base, now=1_788_609_610)
    assert unsupported.savingsPlan.laneStates['transcode'] == 'unsupported'
    assert all(item.kind != 'transcode'
               for item in unsupported.savingsPlan.candidates)
    assert unsupported.savingsPlan.state == 'partial'

    stale = build_media_archive_health(base, now=1_788_610_000)
    assert stale.savingsPlan.state == 'partial'
    assert stale.savingsPlan.candidates == []
    assert stale.savingsPlan.laneStates == {
        'duplicate': 'stale', 'transcode': 'stale', 'retention': 'stale',
    }


def test_duplicate_requires_matching_identity_title_and_positive_spare_bytes():
    base = observation()
    mismatched = playable('b', 4_000).model_copy(update={'title': 'Other'})
    jellyfin = base.jellyfin.model_copy(update={
        'items': [playable('a', 8_000), mismatched],
    })
    result = build_media_archive_health(
        base.model_copy(update={'jellyfin': jellyfin}), now=1_788_609_610)
    assert all(item.kind != 'duplicate' for item in result.savingsPlan.candidates)


def test_plan_is_deterministically_bounded_without_claiming_full_results():
    base = observation()
    items = []
    for number in range(300):
        key = f'movie:tmdb:{number + 1}'
        for suffix, size in (('a', 8_000), ('b', 4_000)):
            items.append(playable(suffix, size).model_copy(update={
                'itemId': f'{number:04x}' * 8 if suffix == 'a'
                else f'{number + 4096:04x}' * 8,
                'mediaKey': key,
                'title': f'Movie {number:03d}',
            }))
    jellyfin = base.jellyfin.model_copy(update={'items': items})
    result = build_media_archive_health(
        base.model_copy(update={'jellyfin': jellyfin}), now=1_788_609_610)
    duplicates = [item for item in result.savingsPlan.candidates
                  if item.kind == 'duplicate']
    assert len(duplicates) == 256
    assert result.savingsPlan.truncated is True
