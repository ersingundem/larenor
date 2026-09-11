from larenor_server.plugins.media_archive_health import build_media_archive_health
from larenor_server.plugins.media_archive_health_models import (
    ArrArchiveSnapshot,
    JellyfinArchiveItem,
    MediaArchiveTranscodeEvidence,
    QbittorrentArchiveSnapshot,
)
from test_media_archive_health import binding, observation


def playable(identifier, size, *, transcode=None, content_hash=None,
             runtime=None):
    return JellyfinArchiveItem(
        itemId=identifier * 32,
        mediaKey='movie:tmdb:603',
        title='The Matrix',
        mediaKind='movie',
        sizeBytes=size,
        integrity='playable',
        transcode=transcode,
        contentHash=content_hash,
        runtimeSeconds=runtime,
    )


def test_builds_explainable_duplicate_transcode_and_retention_review_plan():
    transcode = MediaArchiveTranscodeEvidence(
        sourceCodec='h264', targetCodec='hevc', sourceBitrate=8_000_000,
        targetBitrate=4_000_000, durationSeconds=10,
        targetPlaybackVerified=True,
    )
    base = observation()
    jellyfin = base.jellyfin.model_copy(update={
        'items': [playable('a', 10_000_000, transcode=transcode,
                           content_hash='f' * 64),
                  playable('b', 10_000_000, content_hash='f' * 64)],
        'transcodeEvidence': 'verified',
    })
    result = build_media_archive_health(
        base.model_copy(update={'jellyfin': jellyfin}), now=1_788_609_610)
    plan = result.savingsPlan
    assert plan.state == 'ready'
    assert [(item.kind, item.potentialBytes) for item in plan.candidates] == [
        ('duplicate', 10_000_000),
        ('retention', 4_000),
        ('transcode', 5_000_000),
    ]
    assert plan.laneStates == {
        'duplicate': 'verified', 'transcode': 'verified',
        'retention': 'verified',
    }
    assert plan.totalPotentialBytes == 15_004_000
    assert plan.actionAvailable is False and plan.truncated is False
    assert plan.dataGaps == []
    assert all(item.actionAvailable is False for item in plan.candidates)
    assert plan.candidates[0].evidence == [
        'content_hash_match', 'multiple_playable_files',
        'largest_copy_excluded',
    ]
    assert plan.candidates[0].confidence == 'high'
    assert plan.candidates[0].comparison.model_dump() == {
        'basis': 'keep_largest_copy',
        'observedBytes': 20_000_000,
        'estimatedRetainedBytes': 10_000_000,
        'estimatedSavingBytes': 10_000_000,
    }
    assert plan.candidates[-1].confidence == 'medium'
    assert plan.candidates[-1].comparison.model_dump() == {
        'basis': 'bounded_transcode_estimate',
        'observedBytes': 10_000_000,
        'estimatedRetainedBytes': 5_000_000,
        'estimatedSavingBytes': 5_000_000,
    }
    assert plan.candidates[1].confidence == 'medium'
    assert plan.candidates[1].comparison.model_dump() == {
        'basis': 'review_retained_copy',
        'observedBytes': 4_000,
        'estimatedRetainedBytes': 0,
        'estimatedSavingBytes': 4_000,
    }


def test_plan_suppresses_unproven_candidates_and_marks_lanes_partial():
    base = observation()
    unsupported = build_media_archive_health(base, now=1_788_609_610)
    assert unsupported.savingsPlan.laneStates['transcode'] == 'unsupported'
    assert [value.model_dump() for value in unsupported.savingsPlan.dataGaps] == [
        {'lane': 'transcode', 'reason': 'unsupported'},
    ]
    assert all(item.kind != 'transcode'
               for item in unsupported.savingsPlan.candidates)
    assert unsupported.savingsPlan.state == 'partial'

    stale = build_media_archive_health(base, now=1_788_610_000)
    assert stale.savingsPlan.state == 'partial'
    assert stale.savingsPlan.candidates == []
    assert stale.savingsPlan.laneStates == {
        'duplicate': 'stale', 'transcode': 'stale', 'retention': 'stale',
    }
    assert [value.model_dump() for value in stale.savingsPlan.dataGaps] == [
        {'lane': 'duplicate', 'reason': 'stale'},
        {'lane': 'transcode', 'reason': 'stale'},
        {'lane': 'retention', 'reason': 'stale'},
    ]


def test_unavailable_and_partial_lanes_never_emit_retention_candidates():
    base = observation()
    unavailable_qbt = QbittorrentArchiveSnapshot(
        **binding('qbittorrent', state='unavailable'), items=[])
    unavailable = build_media_archive_health(
        base.model_copy(update={'qbittorrent': unavailable_qbt}),
        now=1_788_609_610,
    )
    assert unavailable.savingsPlan.laneStates['retention'] == 'unavailable'
    assert {'lane': 'retention', 'reason': 'unavailable'} in [
        value.model_dump() for value in unavailable.savingsPlan.dataGaps]
    assert all(item.kind != 'retention'
               for item in unavailable.savingsPlan.candidates)

    unavailable_sonarr = ArrArchiveSnapshot(
        **binding('sonarr', state='unavailable'), items=[])
    partial = build_media_archive_health(
        base.model_copy(update={'sonarr': unavailable_sonarr}),
        now=1_788_609_610,
    )
    assert partial.savingsPlan.laneStates['retention'] == 'partial'
    assert {'lane': 'retention', 'reason': 'partial'} in [
        value.model_dump() for value in partial.savingsPlan.dataGaps]
    assert all(item.kind != 'retention' for item in partial.savingsPlan.candidates)


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
        for suffix in ('a', 'b'):
            items.append(playable(suffix, 4_000).model_copy(update={
                'itemId': f'{number:04x}' * 8 if suffix == 'a'
                else f'{number + 4096:04x}' * 8,
                'mediaKey': key,
                'title': f'Movie {number:03d}',
                'contentHash': f'{number:064x}',
            }))
    jellyfin = base.jellyfin.model_copy(update={'items': items})
    result = build_media_archive_health(
        base.model_copy(update={'jellyfin': jellyfin}), now=1_788_609_610)
    duplicates = [item for item in result.savingsPlan.candidates
                  if item.kind == 'duplicate']
    assert len(duplicates) == 256
    assert result.savingsPlan.truncated is True
    assert {'lane': 'duplicate', 'reason': 'truncated'} in [
        value.model_dump() for value in result.savingsPlan.dataGaps]
