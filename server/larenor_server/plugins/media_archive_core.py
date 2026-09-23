"""Authenticated, bounded, one-shot Core collection for F30 archive health."""

import time

from pydantic import ValidationError

from ..errors import ApiError
from .media_archive_core_models import (
    MediaArchiveAuthorityRequest,
    MediaArchiveCollectionAuthority,
    MediaArchiveReadRequest,
    MediaCatalogSearchRequest,
    PrivateMediaArchiveCollection,
)
from .media_archive_health import build_media_archive_health
from .media_archive_health_models import (
    ArchiveSourceBinding,
    MediaArchiveObservation,
)
from .media_archive_weekly_trend import (
    MediaArchiveTrendError,
    MediaArchiveWeeklyTrendStore,
)
from .media_installations import MAX_INSTALLATIONS

_MAX_AGE_SECONDS = 300
_BINDING_FIELDS = {
    'serviceId', 'serviceRecordId', 'serviceRevision', 'snapshotRevision',
    'installationId', 'installationRevision', 'state', 'observedAt',
}


class MediaArchiveHealthManagement:
    """Coordinates private readers without owning an upstream transport."""

    def __init__(self, db, auth, settings, installations,
                 binding_reader=None, backend=None):
        self.db = db
        self.auth = auth
        self.settings = settings
        self.installations = installations
        self.binding_reader = binding_reader
        self.backend = backend
        self.trends = MediaArchiveWeeklyTrendStore(db)

    def _installation(self, connection, actor, body):
        self.installations._assert_admin(connection, actor)
        row = self.installations._find(connection, body.installationId)
        payload = self.installations._decode(row)
        public = self.installations._public(row, payload)
        if (row['revision'] != body.expectedInstallationRevision
                or row['state'] != 'container_started'
                or row['phase'] != 'complete'
                or row['cancel_requested']
                or row['error_code'] is not None
                or public['serviceId'] != 'jellyfin'):
            raise ApiError('media_installation_changed', 409)

    def _member_installation(self, connection, actor, body):
        row = self._member_target_row(connection, actor)
        if (row['id'] != body.installationId
                or row['revision'] != body.expectedInstallationRevision):
            raise ApiError('media_installation_changed', 409)

    def _member_target_row(self, connection, actor):
        self.auth.assert_current(connection, actor)
        rows = connection.execute(
            'SELECT * FROM media_installations ORDER BY sequence DESC LIMIT ?',
            (MAX_INSTALLATIONS + 1,),
        ).fetchall()
        if len(rows) > MAX_INSTALLATIONS:
            raise ApiError('media_installation_storage_unavailable', 503)
        candidates = []
        for row in rows:
            payload = self.installations._decode(row)
            public = self.installations._public(row, payload)
            if (public['serviceId'] == 'jellyfin'
                    and row['state'] == 'container_started'
                    and row['phase'] == 'complete'
                    and not row['cancel_requested']
                    and row['error_code'] is None):
                candidates.append(row)
        if len(candidates) != 1:
            raise ApiError('media_catalog_target_unavailable', 409)
        return candidates[0]

    def _session_gate(self, actor, body, *, member=False):
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            gate = self._member_installation if member else self._installation
            gate(connection, actor, body)
        return True

    def _authority(self, body, now):
        try:
            value = self.binding_reader.current(body.installationId)
            if type(value) is not MediaArchiveCollectionAuthority:
                raise ValueError()
            current = MediaArchiveCollectionAuthority.model_validate(
                value.model_dump(mode='python'))
        except ApiError:
            raise
        except Exception:
            raise ApiError('media_archive_worker_unavailable', 503) from None
        expected_snapshot = getattr(body, 'expectedSnapshotRevision',
                                    current.snapshotRevision)
        if (current.installationId != body.installationId
                or current.installationRevision
                != body.expectedInstallationRevision
                or current.snapshotRevision != expected_snapshot):
            raise ApiError('media_archive_authority_changed', 409)
        if any(item.observedAt > now
               or now - item.observedAt > _MAX_AGE_SECONDS
               for item in current.sources):
            raise ApiError('media_archive_snapshot_stale', 409)
        return current

    @staticmethod
    def _observation(value):
        if type(value) is not MediaArchiveObservation:
            raise ApiError('media_archive_worker_unavailable', 503)
        try:
            return MediaArchiveObservation.model_validate(
                value.model_dump(mode='python'))
        except (ValidationError, ValueError, TypeError, AttributeError,
                RecursionError, OverflowError):
            raise ApiError('media_archive_worker_unavailable', 503) from None

    @staticmethod
    def _match(authority, observation):
        returned = {
            item.serviceId: ArchiveSourceBinding.model_validate(
                item.model_dump(include=_BINDING_FIELDS, mode='python'))
            for item in (observation.jellyfin, observation.sonarr,
                         observation.radarr, observation.qbittorrent)
        }
        expected = {item.serviceId: item for item in authority.sources}
        if returned != expected:
            raise ApiError('media_archive_authority_changed', 409)

    def _collect(self, actor, body, *, member=False):
        if self.binding_reader is None or self.backend is None:
            raise ApiError('media_archive_worker_unavailable', 503)
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            gate = self._member_installation if member else self._installation
            gate(connection, actor, body)
        now = int(self.settings.clock())
        authority = self._authority(body, now)
        deadline = time.monotonic() + 5

        def gate():
            if time.monotonic() >= deadline:
                return False
            try:
                return self._session_gate(actor, body, member=member)
            except ApiError:
                return False

        private = PrivateMediaArchiveCollection(
            requestId=body.requestId, authority=authority)
        try:
            observed = self.backend.read_media_archive(
                private, deadline=deadline, gate=gate)
        except Exception:
            raise ApiError('media_archive_worker_unavailable', 503) from None
        if time.monotonic() >= deadline:
            raise ApiError('media_archive_worker_unavailable', 503)
        # Preserve authentication error semantics after a late worker result.
        self._session_gate(actor, body, member=member)
        current = self._authority(body, int(self.settings.clock()))
        if current != authority:
            raise ApiError('media_archive_authority_changed', 409)
        observation = self._observation(observed)
        self._match(current, observation)
        return current, observation

    def read(self, actor, body):
        if type(body) is not MediaArchiveReadRequest:
            raise ApiError('invalid_request')
        _current, observation = self._collect(actor, body)
        try:
            archive = build_media_archive_health(
                observation, now=int(self.settings.clock()))
        except (ValidationError, ValueError, TypeError):
            raise ApiError('media_archive_worker_unavailable', 503) from None
        if archive.state == 'incomplete':
            raise ApiError('media_archive_snapshot_stale', 409)
        try:
            trend = self.trends.capture(
                observation, archive, now=archive.generatedAt)
            archive = archive.model_copy(update={'weeklyTrend': trend})
        except MediaArchiveTrendError as error:
            status = 409 if error.code == 'trend_revision_conflict' else 503
            code = ('media_archive_snapshot_stale' if status == 409
                    else 'media_archive_worker_unavailable')
            raise ApiError(code, status) from None
        return {'requestId': body.requestId, 'archive': archive.model_dump()}

    def search(self, actor, body):
        if type(body) is not MediaCatalogSearchRequest:
            raise ApiError('invalid_request')
        current, observation = self._collect(actor, body)
        return self._search_response(body, current, observation)

    @staticmethod
    def _search_response(body, current, observation):
        query = body.query.casefold()
        items = [
            item for item in observation.jellyfin.items
            if item.integrity == 'playable'
            and query in item.title.casefold()
            and (body.mediaKind is None or item.mediaKind == body.mediaKind)
        ]
        items.sort(key=lambda item: (
            item.title.casefold(), item.mediaKey, item.itemId))
        if body.offset > len(items):
            raise ApiError('invalid_request')
        selected = items[body.offset:body.offset + body.limit]
        end = body.offset + len(selected)
        source = next(
            item for item in current.sources if item.serviceId == 'jellyfin')
        return {
            'requestId': body.requestId,
            'catalog': {
                'schemaVersion': 1,
                'installationId': current.installationId,
                'installationRevision': current.installationRevision,
                'snapshotRevision': current.snapshotRevision,
                'jellyfinServiceRevision': source.serviceRevision,
                'offset': body.offset,
                'nextOffset': end if end < len(items) else None,
                'total': len(items),
                'items': [{
                    'itemId': item.itemId,
                    'mediaKey': item.mediaKey,
                    'title': item.title,
                    'mediaKind': item.mediaKind,
                    'runtimeSeconds': item.runtimeSeconds,
                } for item in selected],
            },
        }

    def member_search(self, actor, body):
        if type(body) is not MediaCatalogSearchRequest:
            raise ApiError('invalid_request')
        current, observation = self._collect(actor, body, member=True)
        return self._search_response(body, current, observation)

    def member_target(self, actor):
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            row = self._member_target_row(connection, actor)
        body = MediaArchiveAuthorityRequest(
            requestId='0' * 32,
            installationId=row['id'],
            expectedInstallationRevision=row['revision'],
        )
        current = self._authority(body, int(self.settings.clock()))
        self._session_gate(actor, body, member=True)
        source = next(
            item for item in current.sources if item.serviceId == 'jellyfin')
        return {
            'schemaVersion': 1,
            'installationId': current.installationId,
            'installationRevision': current.installationRevision,
            'snapshotRevision': current.snapshotRevision,
            'jellyfinServiceRevision': source.serviceRevision,
        }

    def authority(self, actor, body):
        """Return only the revisions needed to make a subsequent exact read."""
        if type(body) is not MediaArchiveAuthorityRequest:
            raise ApiError('invalid_request')
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._installation(connection, actor, body)
        current = self._authority(body, int(self.settings.clock()))
        return {
            'requestId': body.requestId,
            'installationId': current.installationId,
            'installationRevision': current.installationRevision,
            'snapshotRevision': current.snapshotRevision,
        }
