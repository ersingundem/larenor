"""Restart-durable, bounded weekly projections for F30 archive evidence."""

from hashlib import sha256
import json
import sqlite3

from pydantic import ValidationError

from .media_archive_health_models import (
    MediaArchiveHealth,
    MediaArchiveObservation,
    MediaArchiveWeeklyTrend,
    MediaArchiveWeeklyTrendPoint,
)


_WEEK_SECONDS = 7 * 24 * 60 * 60
_STALE_SECONDS = 8 * 24 * 60 * 60
_COLUMNS = (
    'installation_id', 'installation_revision', 'week_start', 'captured_at',
    'snapshot_revision', 'total_bytes', 'free_bytes', 'reclaimable_bytes',
    'duplicate_candidates', 'low_quality_candidates',
)


class MediaArchiveTrendError(ValueError):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def _week_start(timestamp):
    # 1970-01-01 was Thursday; shift the epoch so integer weeks start Monday.
    days = timestamp // 86400
    return (days - ((days + 3) % 7)) * 86400


def _digest(values):
    wire = json.dumps(values, sort_keys=True, separators=(',', ':'))
    return sha256(wire.encode('ascii')).hexdigest()


def _point(row):
    values = {name: row[name] for name in _COLUMNS}
    if (type(row['digest']) is not str or len(row['digest']) != 64
            or _digest(values) != row['digest']):
        raise MediaArchiveTrendError('trend_unavailable')
    try:
        return MediaArchiveWeeklyTrendPoint(
            weekStart=values['week_start'], capturedAt=values['captured_at'],
            snapshotRevision=values['snapshot_revision'],
            totalBytes=values['total_bytes'], freeBytes=values['free_bytes'],
            reclaimableBytes=values['reclaimable_bytes'],
            duplicateCandidates=values['duplicate_candidates'],
            lowQualityCandidates=values['low_quality_candidates'])
    except (ValidationError, ValueError, TypeError, OverflowError):
        raise MediaArchiveTrendError('trend_unavailable') from None


class MediaArchiveWeeklyTrendStore:
    """Keeps one exact point per UTC week and at most twelve per installation."""

    def __init__(self, db):
        self.db = db

    @staticmethod
    def _values(observation, archive, now):
        if (type(observation) is not MediaArchiveObservation
                or type(archive) is not MediaArchiveHealth
                or type(now) is not int or now < 1
                or archive.state == 'incomplete'):
            raise MediaArchiveTrendError('trend_unavailable')
        capacity = observation.capacity
        if capacity is None or capacity.state != 'verified':
            return None
        if (archive.installationId != observation.jellyfin.installationId
                or archive.installationRevision
                != observation.jellyfin.installationRevision
                or archive.snapshotRevision != capacity.snapshotRevision
                or archive.generatedAt != now):
            raise MediaArchiveTrendError('trend_revision_conflict')
        duplicates = sum(
            item.groupReason in {
                'exact_content_hash', 'probable_name_size_runtime'}
            for item in archive.savingsPlan.candidates)
        low_quality = sum(
            item.groupReason == 'lower_quality_variant'
            for item in archive.savingsPlan.candidates)
        return {
            'installation_id': archive.installationId,
            'installation_revision': archive.installationRevision,
            'week_start': _week_start(now),
            'captured_at': now,
            'snapshot_revision': archive.snapshotRevision,
            'total_bytes': capacity.totalBytes,
            'free_bytes': capacity.freeBytes,
            'reclaimable_bytes': archive.savingsPlan.totalPotentialBytes,
            'duplicate_candidates': duplicates,
            'low_quality_candidates': low_quality,
        }

    def capture(self, observation, archive, *, now):
        values = self._values(observation, archive, now)
        if values is None:
            return self.current(
                archive.installationId, archive.installationRevision,
                now=now, currentVerified=False)
        try:
            with self.db.transaction() as connection:
                connection.execute(
                    'DELETE FROM media_archive_weekly_trends '
                    'WHERE installation_id=? AND installation_revision<>?',
                    (values['installation_id'],
                     values['installation_revision']))
                latest = connection.execute(
                    'SELECT * FROM media_archive_weekly_trends '
                    'WHERE installation_id=? AND installation_revision=? '
                    'ORDER BY week_start DESC LIMIT 1',
                    (values['installation_id'],
                     values['installation_revision'])).fetchone()
                old = connection.execute(
                    'SELECT * FROM media_archive_weekly_trends '
                    'WHERE installation_id=? AND week_start=?',
                    (values['installation_id'], values['week_start'])).fetchone()
                encoded = {**values, 'digest': _digest(values)}
                if (latest is not None
                        and latest['week_start'] != values['week_start']
                        and (values['snapshot_revision']
                             <= latest['snapshot_revision']
                             or values['captured_at'] <= latest['captured_at']
                             or values['week_start'] <= latest['week_start'])):
                    raise MediaArchiveTrendError('trend_revision_conflict')
                if old is not None:
                    previous = {name: old[name] for name in _COLUMNS}
                    if previous == values and old['digest'] == encoded['digest']:
                        pass
                    elif (values['snapshot_revision'] <= old['snapshot_revision']
                          or values['captured_at'] < old['captured_at']):
                        raise MediaArchiveTrendError('trend_revision_conflict')
                    else:
                        connection.execute('''UPDATE media_archive_weekly_trends SET
                            installation_revision=:installation_revision,
                            captured_at=:captured_at,
                            snapshot_revision=:snapshot_revision,
                            total_bytes=:total_bytes, free_bytes=:free_bytes,
                            reclaimable_bytes=:reclaimable_bytes,
                            duplicate_candidates=:duplicate_candidates,
                            low_quality_candidates=:low_quality_candidates,
                            digest=:digest
                            WHERE installation_id=:installation_id
                              AND week_start=:week_start''', encoded)
                else:
                    connection.execute('''INSERT INTO media_archive_weekly_trends (
                        installation_id, installation_revision, week_start,
                        captured_at, snapshot_revision, total_bytes, free_bytes,
                        reclaimable_bytes, duplicate_candidates,
                        low_quality_candidates, digest
                    ) VALUES (
                        :installation_id, :installation_revision, :week_start,
                        :captured_at, :snapshot_revision, :total_bytes, :free_bytes,
                        :reclaimable_bytes, :duplicate_candidates,
                        :low_quality_candidates, :digest)''', encoded)
                connection.execute('''DELETE FROM media_archive_weekly_trends
                    WHERE installation_id=? AND installation_revision=?
                      AND week_start NOT IN (
                        SELECT week_start FROM media_archive_weekly_trends
                        WHERE installation_id=? AND installation_revision=?
                        ORDER BY week_start DESC LIMIT 12)''', (
                    values['installation_id'], values['installation_revision'],
                    values['installation_id'], values['installation_revision']))
        except MediaArchiveTrendError:
            raise
        except (sqlite3.Error, ValueError, TypeError, OverflowError):
            raise MediaArchiveTrendError('trend_unavailable') from None
        return self.current(
            archive.installationId, archive.installationRevision,
            now=now, currentVerified=True)

    def current(self, installationId, installationRevision, *, now,
                currentVerified):
        if (type(installationId) is not str or len(installationId) != 32
                or type(installationRevision) is not int
                or installationRevision < 1 or type(now) is not int
                or now < 1 or type(currentVerified) is not bool):
            raise MediaArchiveTrendError('trend_unavailable')
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    'SELECT * FROM media_archive_weekly_trends '
                    'WHERE installation_id=? AND installation_revision=? '
                    'ORDER BY week_start',
                    (installationId, installationRevision)).fetchall()
            if len(rows) > 12:
                raise MediaArchiveTrendError('trend_unavailable')
            points = [_point(row) for row in rows]
        except MediaArchiveTrendError:
            raise
        except (sqlite3.Error, ValueError, TypeError, OverflowError):
            raise MediaArchiveTrendError('trend_unavailable') from None
        if not points:
            return MediaArchiveWeeklyTrend(
                state='unavailable', points=[], actionAvailable=False)
        latest = points[-1]
        state = ('ready' if currentVerified and latest.capturedAt <= now
                 and now - latest.capturedAt <= _STALE_SECONDS else 'stale')
        return MediaArchiveWeeklyTrend(
            state=state, points=points, actionAvailable=False)
