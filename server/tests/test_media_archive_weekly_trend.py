import json

import pytest
from pydantic import ValidationError

from larenor_server.plugins.media_archive_health import build_media_archive_health
from larenor_server.plugins.media_archive_health_models import (
    MediaArchiveCapacityEvidence,
)
from larenor_server.plugins.media_archive_weekly_trend import (
    MediaArchiveTrendError,
    MediaArchiveWeeklyTrendStore,
)
from conftest import auth
from test_media_archive_core_read import BASE, configured
from test_media_archive_health import binding, observation


GIB = 1_000_000_000
WEEK = 7 * 24 * 60 * 60


def capacity(*, snapshot=7, total=1_000 * GIB, free=300 * GIB):
    return MediaArchiveCapacityEvidence(
        source='sonarr', serviceRevision=7, snapshotRevision=snapshot,
        state='verified', totalBytes=total, freeBytes=free)


def health(*, snapshot=7, now=1_788_609_610):
    base = observation()
    source = observation(
        capacity=capacity(snapshot=snapshot),
        **{
            name: getattr(base, name).model_copy(update={
                'snapshotRevision': snapshot, 'observedAt': now - 10,
            })
            for name in ('jellyfin', 'sonarr', 'radarr', 'qbittorrent')
        },
    )
    return source, build_media_archive_health(source, now=now)


def test_capacity_contract_is_exact_secret_free_and_source_bound():
    source, _archive = health()
    assert source.capacity.totalBytes == 1_000 * GIB
    assert 'path' not in json.dumps(source.capacity.model_dump()).lower()
    with pytest.raises(ValidationError):
        MediaArchiveCapacityEvidence.model_validate({
            **capacity().model_dump(), 'token': 'must-not-survive'})
    with pytest.raises(ValidationError):
        MediaArchiveCapacityEvidence(
            source='sonarr', serviceRevision=7, snapshotRevision=7,
            state='verified', totalBytes=100, freeBytes=101)
    with pytest.raises(ValidationError):
        observation(capacity=capacity(snapshot=8))


def test_store_keeps_only_latest_twelve_utc_weeks_and_exact_metrics(server):
    db = server[0].state.core.db
    store = MediaArchiveWeeklyTrendStore(db)
    first = 1_788_609_610
    for index in range(13):
        now = first + index * WEEK
        source, archive = health(snapshot=index + 1, now=now)
        trend = store.capture(source, archive, now=now)
    assert trend.state == 'ready'
    assert len(trend.points) == 12
    assert [point.snapshotRevision for point in trend.points] == list(range(2, 14))
    assert trend.points[-1].model_dump() == {
        'weekStart': trend.points[-1].weekStart,
        'capturedAt': first + 12 * WEEK,
        'snapshotRevision': 13,
        'totalBytes': 1_000 * GIB,
        'freeBytes': 300 * GIB,
        'reclaimableBytes': 4_000,
        'duplicateCandidates': 0,
        'lowQualityCandidates': 0,
    }
    assert trend.actionAvailable is False
    reopened = MediaArchiveWeeklyTrendStore(db).current(
        '1' * 32, 11,
        now=first + 12 * WEEK, currentVerified=True)
    assert reopened == trend


def test_same_week_is_idempotent_but_rollback_or_changed_replay_fails(server):
    store = MediaArchiveWeeklyTrendStore(server[0].state.core.db)
    source, archive = health(snapshot=7)
    initial = store.capture(source, archive, now=1_788_609_610)
    assert store.capture(source, archive, now=1_788_609_610) == initial
    changed_capacity = capacity(snapshot=7, free=299 * GIB)
    changed_source = observation(capacity=changed_capacity)
    changed_archive = build_media_archive_health(changed_source, now=1_788_609_610)
    with pytest.raises(MediaArchiveTrendError, match='trend_revision_conflict'):
        store.capture(changed_source, changed_archive, now=1_788_609_610)

    newer_source = observation(
        capacity=capacity(snapshot=8),
        jellyfin=observation().jellyfin.model_copy(update={'snapshotRevision': 8}),
        sonarr=observation().sonarr.model_copy(update={'snapshotRevision': 8}),
        radarr=observation().radarr.model_copy(update={'snapshotRevision': 8}),
        qbittorrent=observation().qbittorrent.model_copy(update={'snapshotRevision': 8}),
    )
    newer_archive = build_media_archive_health(newer_source, now=1_788_609_610)
    assert store.capture(
        newer_source, newer_archive, now=1_788_609_610
    ).points[-1].snapshotRevision == 8
    with pytest.raises(MediaArchiveTrendError, match='trend_revision_conflict'):
        store.capture(source, archive, now=1_788_609_610)

    rollback_source, rollback_archive = health(
        snapshot=9, now=1_788_609_610 - WEEK)
    with pytest.raises(MediaArchiveTrendError, match='trend_revision_conflict'):
        store.capture(
            rollback_source, rollback_archive,
            now=1_788_609_610 - WEEK)


def test_missing_current_capacity_distinguishes_unavailable_and_stale(server):
    store = MediaArchiveWeeklyTrendStore(server[0].state.core.db)
    unavailable = store.current(
        '1' * 32, 11, now=1_788_609_610, currentVerified=False)
    assert unavailable.state == 'unavailable' and unavailable.points == []

    source, archive = health()
    store.capture(source, archive, now=1_788_609_610)
    stale = store.current(
        archive.installationId, archive.installationRevision,
        now=1_788_609_611, currentVerified=False)
    assert stale.state == 'stale' and len(stale.points) == 1
    expired = store.current(
        archive.installationId, archive.installationRevision,
        now=1_788_609_610 + 8 * 24 * 60 * 60 + 1, currentVerified=True)
    assert expired.state == 'stale'


def test_tampered_row_fails_closed_without_leaking_database_values(server):
    store = MediaArchiveWeeklyTrendStore(server[0].state.core.db)
    source, archive = health()
    store.capture(source, archive, now=1_788_609_610)
    with server[0].state.core.db.transaction() as connection:
        connection.execute(
            'UPDATE media_archive_weekly_trends SET free_bytes=?', (1,))
    with pytest.raises(MediaArchiveTrendError, match='trend_unavailable'):
        store.current(
            archive.installationId, archive.installationRevision,
            now=1_788_609_611, currentVerified=True)


def test_core_read_captures_verified_capacity_then_marks_missing_evidence_stale(
        server):
    pair, _installation, _current, _reader, worker, body = configured(server)
    observed = worker.result
    worker.result = observed.model_copy(update={
        'capacity': MediaArchiveCapacityEvidence(
            source='sonarr',
            serviceRevision=observed.sonarr.serviceRevision,
            snapshotRevision=observed.sonarr.snapshotRevision,
            state='verified', totalBytes=1_000 * GIB, freeBytes=300 * GIB),
    })
    ready = server[1].post(BASE, headers=auth(pair), json=body)
    assert ready.status_code == 200, ready.text
    assert ready.json()['archive']['weeklyTrend']['state'] == 'ready'
    assert len(ready.json()['archive']['weeklyTrend']['points']) == 1

    worker.result = observed
    stale = server[1].post(BASE, headers=auth(pair), json={
        **body, 'requestId': 'f' * 32,
    })
    assert stale.status_code == 200, stale.text
    assert stale.json()['archive']['weeklyTrend']['state'] == 'stale'
    assert len(stale.json()['archive']['weeklyTrend']['points']) == 1
    assert all(value not in stale.text.lower() for value in (
        'token', 'password', 'cookie', 'endpoint', '/media/'))
