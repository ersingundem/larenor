"""Bounded explainable review plan derived only from verified archive facts."""

from collections import defaultdict

from .media_archive_health_models import (
    MediaArchiveSavingsCandidate,
    MediaArchiveSavingsPlan,
)


_LIMIT_PER_LANE = 256


def _source_lane(state):
    return state if state in ('unavailable', 'unsupported', 'stale') else 'verified'


def build_media_archive_savings_plan(observation, source_states):
    jellyfin_state = _source_lane(source_states['jellyfin'])
    duplicate_state = jellyfin_state
    transcode_state = (
        jellyfin_state if jellyfin_state != 'verified'
        else observation.jellyfin.transcodeEvidence)
    retention_state = _source_lane(source_states['qbittorrent'])
    if retention_state == 'verified' and set(source_states.values()) != {'verified'}:
        retention_state = 'partial'
    lanes = {
        'duplicate': duplicate_state,
        'transcode': transcode_state,
        'retention': retention_state,
    }
    by_kind = {'duplicate': [], 'transcode': [], 'retention': []}

    if duplicate_state == 'verified':
        grouped = defaultdict(list)
        for item in observation.jellyfin.items:
            if item.integrity == 'playable':
                grouped[item.mediaKey].append(item)
        for values in grouped.values():
            if (len(values) < 2 or len({item.title for item in values}) != 1
                    or any(item.sizeBytes <= 0 for item in values)):
                continue
            potential = sum(item.sizeBytes for item in values) - max(
                item.sizeBytes for item in values)
            if potential > 0:
                observed = sum(item.sizeBytes for item in values)
                retained = max(item.sizeBytes for item in values)
                by_kind['duplicate'].append(MediaArchiveSavingsCandidate(
                    kind='duplicate', source='jellyfin', title=values[0].title,
                    potentialBytes=potential,
                    confidence='high',
                    comparison={
                        'basis': 'keep_largest_copy',
                        'observedBytes': observed,
                        'estimatedRetainedBytes': retained,
                        'estimatedSavingBytes': potential,
                    },
                    evidence=['same_media_identity', 'multiple_playable_files',
                              'largest_copy_excluded'], actionAvailable=False))

    if transcode_state == 'verified':
        for item in observation.jellyfin.items:
            proof = item.transcode
            if item.integrity != 'playable' or proof is None:
                continue
            estimate = ((proof.sourceBitrate - proof.targetBitrate)
                        * proof.durationSeconds) // 8
            potential = min(item.sizeBytes, estimate)
            if potential > 0:
                by_kind['transcode'].append(MediaArchiveSavingsCandidate(
                    kind='transcode', source='jellyfin', title=item.title,
                    potentialBytes=potential,
                    confidence='medium',
                    comparison={
                        'basis': 'bounded_transcode_estimate',
                        'observedBytes': item.sizeBytes,
                        'estimatedRetainedBytes': item.sizeBytes - potential,
                        'estimatedSavingBytes': potential,
                    },
                    evidence=['source_profile_verified',
                              'target_playback_verified',
                              'bounded_size_estimate'], actionAvailable=False))

    if retention_state == 'verified':
        for item in observation.qbittorrent.items:
            if (item.state == 'complete' and item.importedConfirmed
                    and item.retentionPolicySatisfied
                    and item.mediaKey is not None and item.contentBytes > 0):
                by_kind['retention'].append(MediaArchiveSavingsCandidate(
                    kind='retention', source='qbittorrent', title=item.title,
                    potentialBytes=item.contentBytes,
                    confidence='medium',
                    comparison={
                        'basis': 'review_retained_copy',
                        'observedBytes': item.contentBytes,
                        'estimatedRetainedBytes': 0,
                        'estimatedSavingBytes': item.contentBytes,
                    },
                    evidence=['download_complete', 'import_verified',
                              'retention_policy_satisfied'],
                    actionAvailable=False))

    truncated_lanes = {
        kind for kind, values in by_kind.items()
        if len(values) > _LIMIT_PER_LANE
    }
    truncated = bool(truncated_lanes)
    candidates = []
    for kind, values in by_kind.items():
        values.sort(key=lambda item: (item.title.casefold(), item.title,
                                      item.potentialBytes))
        candidates.extend(values[:_LIMIT_PER_LANE])
    candidates.sort(key=lambda item: (item.kind, item.title.casefold(),
                                      item.title, item.potentialBytes))
    counts = {kind: sum(item.kind == kind for item in candidates)
              for kind in by_kind}
    data_gaps = []
    for kind in ('duplicate', 'transcode', 'retention'):
        if lanes[kind] != 'verified':
            data_gaps.append({'lane': kind, 'reason': lanes[kind]})
        elif kind in truncated_lanes:
            data_gaps.append({'lane': kind, 'reason': 'truncated'})
    ready = not data_gaps
    return MediaArchiveSavingsPlan(
        state='ready' if ready else 'partial', laneStates=lanes,
        candidates=candidates, candidateCounts=counts,
        totalPotentialBytes=sum(item.potentialBytes for item in candidates),
        dataGaps=data_gaps, truncated=truncated, actionAvailable=False)
