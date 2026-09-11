"""Authenticated, bounded, one-shot Core collection for F30 archive health."""

import time

from pydantic import ValidationError

from ..errors import ApiError
from .media_archive_core_models import (
    MediaArchiveCollectionAuthority,
    MediaArchiveReadRequest,
    PrivateMediaArchiveCollection,
)
from .media_archive_health import build_media_archive_health
from .media_archive_health_models import (
    ArchiveSourceBinding,
    MediaArchiveObservation,
)


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

    def _installation(self, connection, actor, body):
        self.installations._assert_admin(connection, actor)
        row = self.installations._find(connection, body.installationId)
        payload = self.installations._decode(row)
        public = self.installations._public(row, payload)
        if (row['revision'] != body.expectedInstallationRevision
                or row['state'] != 'container_started'
                or public['serviceId'] != 'jellyfin'):
            raise ApiError('media_installation_changed', 409)

    def _session_gate(self, actor, body):
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._installation(connection, actor, body)
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
        if (current.installationId != body.installationId
                or current.installationRevision
                != body.expectedInstallationRevision
                or current.snapshotRevision != body.expectedSnapshotRevision):
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

    def read(self, actor, body):
        if type(body) is not MediaArchiveReadRequest:
            raise ApiError('invalid_request')
        if self.binding_reader is None or self.backend is None:
            raise ApiError('media_archive_worker_unavailable', 503)
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._installation(connection, actor, body)
        now = int(self.settings.clock())
        authority = self._authority(body, now)
        deadline = time.monotonic() + 5

        def gate():
            if time.monotonic() >= deadline:
                return False
            try:
                return self._session_gate(actor, body)
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
        self._session_gate(actor, body)
        current = self._authority(body, int(self.settings.clock()))
        if current != authority:
            raise ApiError('media_archive_authority_changed', 409)
        observation = self._observation(observed)
        self._match(current, observation)
        try:
            archive = build_media_archive_health(
                observation, now=int(self.settings.clock()))
        except (ValidationError, ValueError, TypeError):
            raise ApiError('media_archive_worker_unavailable', 503) from None
        if archive.state == 'incomplete':
            raise ApiError('media_archive_snapshot_stale', 409)
        return {'requestId': body.requestId, 'archive': archive.model_dump()}
