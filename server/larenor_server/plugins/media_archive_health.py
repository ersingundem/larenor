"""Pure read-only aggregation for archive health and space review."""

from .media_archive_health_models import (
    MediaArchiveCounts,
    MediaArchiveHealth,
    MediaArchiveIssue,
    MediaArchiveObservation,
    MediaArchiveSavingSuggestion,
)


_MAX_AGE_SECONDS = 300


def build_media_archive_health(observation, *, now):
    if type(observation) is not MediaArchiveObservation or type(now) is not int:
        raise ValueError('archive_observation_invalid')
    sources = (
        observation.jellyfin, observation.sonarr,
        observation.radarr, observation.qbittorrent,
    )
    if any(source.observedAt > now for source in sources):
        raise ValueError('archive_observation_invalid')
    authority = {
        (source.installationId, source.installationRevision,
         source.snapshotRevision) for source in sources
    }
    if len(authority) != 1:
        raise ValueError('archive_authority_changed')

    source_states = {}
    for source in sources:
        state = source.state
        if state == 'verified' and now - source.observedAt > _MAX_AGE_SECONDS:
            state = 'stale'
        source_states[source.serviceId] = state
    complete = all(state == 'verified' for state in source_states.values())

    issues = []
    if source_states['jellyfin'] == 'verified':
        for item in observation.jellyfin.items:
            if item.integrity == 'playable':
                continue
            code = {
                'missing_file': 'missing_file',
                'corrupt': 'corrupt_media',
                'unplayable': 'unplayable_media',
            }[item.integrity]
            issues.append(MediaArchiveIssue(
                code=code, severity='critical', source='jellyfin',
                sourceItemId=item.itemId, mediaKey=item.mediaKey,
                title=item.title, observedBytes=item.sizeBytes,
            ))
    for source in (observation.sonarr, observation.radarr):
        if source_states[source.serviceId] != 'verified':
            continue
        for item in source.items:
            if item.monitored and item.state == 'missing':
                issues.append(MediaArchiveIssue(
                    code='missing_media', severity='warning',
                    source=source.serviceId, sourceItemId=item.mediaKey,
                    mediaKey=item.mediaKey, title=item.title, observedBytes=0,
                ))
    if source_states['qbittorrent'] == 'verified':
        for item in observation.qbittorrent.items:
            if item.state == 'error':
                issues.append(MediaArchiveIssue(
                    code='download_error', severity='warning',
                    source='qbittorrent', sourceItemId=item.torrentId,
                    mediaKey=item.mediaKey,
                    title=item.title, observedBytes=item.contentBytes,
                ))

    suggestions = []
    if complete:
        for item in observation.qbittorrent.items:
            if (item.state == 'complete' and item.importedConfirmed
                    and item.retentionPolicySatisfied
                    and item.mediaKey is not None and item.contentBytes > 0):
                suggestions.append(MediaArchiveSavingSuggestion(
                    code='review_retained_download', torrentId=item.torrentId,
                    mediaKey=item.mediaKey, title=item.title,
                    potentialBytes=item.contentBytes,
                    evidence=['download_complete', 'import_verified',
                              'retention_policy_satisfied'],
                    cleanupAvailable=False,
                ))

    missing = sum(issue.code == 'missing_media' for issue in issues)
    broken = sum(issue.code in {
        'missing_file', 'corrupt_media', 'unplayable_media'} for issue in issues)
    failed = sum(issue.code == 'download_error' for issue in issues)
    installation_id, installation_revision, snapshot_revision = next(iter(authority))
    state = ('incomplete' if not complete
             else ('attention' if issues or suggestions else 'healthy'))
    return MediaArchiveHealth(
        installationId=installation_id,
        installationRevision=installation_revision,
        snapshotRevision=snapshot_revision,
        state=state,
        sourceStates=source_states,
        sourceRevisions={source.serviceId: source.serviceRevision
                         for source in sources},
        counts=MediaArchiveCounts(
            missing=missing, broken=broken, failedDownloads=failed,
            savingCandidates=len(suggestions),
            potentialSavingBytes=sum(item.potentialBytes for item in suggestions),
        ),
        issues=issues, suggestions=suggestions,
        cleanupAvailable=False, generatedAt=now,
    )
