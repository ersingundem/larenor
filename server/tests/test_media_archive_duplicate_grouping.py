from larenor_server.plugins.media_archive_health import build_media_archive_health
from larenor_server.plugins.media_archive_health_models import JellyfinArchiveItem
from test_media_archive_health import observation


def item(identifier, *, title='Movie', size=8_000, runtime=600,
         content_hash=None, width=None, height=None, bitrate=None):
    quality = None if width is None else {
        'width': width, 'height': height, 'videoBitrate': bitrate,
    }
    return JellyfinArchiveItem(
        itemId=identifier * 32,
        mediaKey='movie:tmdb:603',
        title=title,
        mediaKind='movie',
        sizeBytes=size,
        integrity='playable',
        contentHash=content_hash,
        runtimeSeconds=runtime,
        quality=quality,
    )


def health(items):
    base = observation()
    jellyfin = base.jellyfin.model_copy(update={'items': items})
    return build_media_archive_health(
        base.model_copy(update={'jellyfin': jellyfin}),
        now=1_788_609_610,
    )


def duplicates(result):
    return [candidate for candidate in result.savingsPlan.candidates
            if candidate.kind == 'duplicate']


def test_hash_match_is_exact_and_exposes_bounded_reclaimable_bytes():
    digest = 'a' * 64
    candidates = duplicates(health([
        item('a', content_hash=digest),
        item('b', content_hash=digest),
    ]))
    assert len(candidates) == 1
    candidate = candidates[0]
    assert candidate.groupReason == 'exact_content_hash'
    assert candidate.confidence == 'high'
    assert candidate.potentialBytes == 8_000
    assert candidate.evidence == [
        'content_hash_match', 'multiple_playable_files',
        'largest_copy_excluded',
    ]


def test_missing_hash_only_allows_probable_name_size_runtime_group():
    candidates = duplicates(health([item('a'), item('b')]))
    assert len(candidates) == 1
    candidate = candidates[0]
    assert candidate.groupReason == 'probable_name_size_runtime'
    assert candidate.confidence == 'medium'
    assert candidate.potentialBytes == 8_000
    assert candidate.evidence[0] == 'name_size_runtime_match'

    mismatch = duplicates(health([item('a'), item('b', runtime=601)]))
    assert mismatch == []


def test_verified_lower_quality_variant_is_grouped_without_mutation():
    candidates = duplicates(health([
        item('a', size=12_000, content_hash='a' * 64,
             width=3840, height=2160, bitrate=20_000_000),
        item('b', size=4_000, content_hash='b' * 64,
             width=1280, height=720, bitrate=3_000_000),
    ]))
    assert len(candidates) == 1
    candidate = candidates[0]
    assert candidate.groupReason == 'lower_quality_variant'
    assert candidate.confidence == 'medium'
    assert candidate.potentialBytes == 4_000
    assert candidate.comparison.model_dump() == {
        'basis': 'keep_best_quality_copy',
        'observedBytes': 16_000,
        'estimatedRetainedBytes': 12_000,
        'estimatedSavingBytes': 4_000,
    }
    assert candidate.evidence == [
        'same_media_identity', 'quality_profile_comparison',
        'best_quality_excluded',
    ]
    assert candidate.actionAvailable is False
