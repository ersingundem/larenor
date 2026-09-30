"""Core-owned F30 authority, credential resolution and durable observations."""

from dataclasses import dataclass
import hashlib
import hmac
import json
import re
import sqlite3
import time
import uuid

from pydantic import ValidationError

from ..errors import ApiError, StartupError
from .arr_config_job_models import PrivateArrReceipt
from .media_archive_core_models import (
    MediaArchiveCollectionAuthority,
    PrivateMediaArchiveCollection,
    PrivateMediaArchiveSourceCredential,
    PrivateMediaArchiveWorkerCollection,
)
from .media_archive_health_models import (
    ArchiveSourceBinding,
    MediaArchiveObservation,
)
from .qbittorrent_config_job_models import PrivateQbittorrentReceipt


_ID = re.compile(r'[0-9a-f]{32}\Z')
_DIGEST = re.compile(r'[0-9a-f]{64}\Z')
_MAX_AGE_SECONDS = 300
_REFRESH_SECONDS = 240
_MAX_SNAPSHOTS = 16
_BINDING_FIELDS = set(ArchiveSourceBinding.model_fields)
_ORDER = ('jellyfin', 'sonarr', 'radarr', 'qbittorrent')


@dataclass(frozen=True, repr=False)
class _ResolvedArchiveSource:
    installation_revision: int
    fingerprint: str
    plan: object
    sources: tuple[PrivateMediaArchiveSourceCredential, ...]

    def __repr__(self):
        return '_ResolvedArchiveSource(<private>)'


def _canonical(value):
    return json.dumps(
        value, sort_keys=True, separators=(',', ':'), ensure_ascii=True,
        allow_nan=False).encode('ascii')


def _digest(value):
    return hashlib.sha256(_canonical(value)).hexdigest()


class MediaArchiveWorkerProvider:
    """Keeps secrets in Core and exposes immutable secret-free snapshots."""

    def __init__(self, db, settings, installations, bootstraps, qbittorrent,
                 arr, backend):
        required = (
            callable(getattr(backend, 'read_media_archive', None)),
            callable(getattr(installations, '_decode', None)),
            callable(getattr(bootstraps, '_validate_row', None)),
            callable(getattr(qbittorrent, '_validate_row', None)),
            callable(getattr(arr, '_validate_row', None)),
        )
        if not all(required):
            raise ValueError('invalid_media_archive_provider')
        self.db, self.settings = db, settings
        self.installations, self.bootstraps = installations, bootstraps
        self.qbittorrent, self.arr, self.backend = qbittorrent, arr, backend

    def __repr__(self):
        return 'MediaArchiveWorkerProvider(<private>)'

    @staticmethod
    def _terminal(row):
        return (row['state'] == 'succeeded' and row['phase'] == 'complete'
                and not row['cancel_requested'] and row['error_code'] is None)

    def _resolve(self, connection, installation_id):
        if type(installation_id) is not str or _ID.fullmatch(installation_id) is None:
            raise ValueError('media_archive_authority_unavailable')
        installation = connection.execute(
            'SELECT * FROM media_installations WHERE id=?',
            (installation_id,)).fetchone()
        if installation is None:
            raise ValueError('media_archive_authority_unavailable')
        installed = self.installations._decode(installation)
        if (installation['state'] != 'container_started'
                or installation['phase'] != 'complete'
                or installation['cancel_requested']
                or installation['error_code'] is not None
                or installed.request.serviceId != 'jellyfin'):
            raise ValueError('media_archive_authority_unavailable')
        preparation_id = installation['preparation_id']
        common = (installation['actor_id'], installation['actor_revision'],
                  installation['family_id'], installation['inspection_id'])

        bootstrap = connection.execute(
            'SELECT * FROM media_service_bootstraps WHERE installation_id=?',
            (installation_id,)).fetchone()
        if bootstrap is None:
            raise ValueError('media_archive_authority_unavailable')
        jellyfin = self.bootstraps._validate_row(connection, bootstrap)
        if (bootstrap['installation_revision'] != installation['revision']
                or bootstrap['state'] not in {'wiring_partial', 'succeeded'}
                or bootstrap['credentials_configured'] != 1
                or bootstrap['wiring_state'] != (
                    'partial' if bootstrap['state'] == 'wiring_partial'
                    else 'verified')
                or bootstrap['error_code'] is not None
                or jellyfin.readback is None
                or (bootstrap['actor_id'], bootstrap['actor_revision'],
                    bootstrap['family_id']) != common[:3]):
            raise ValueError('media_archive_authority_unavailable')

        qb_row = connection.execute(
            'SELECT * FROM media_qbittorrent_configurations '
            'WHERE preparation_id=?', (preparation_id,)).fetchone()
        if qb_row is None:
            raise ValueError('media_archive_authority_unavailable')
        qb = self.qbittorrent._validate_row(connection, qb_row)
        qb_receipt = qb.receipt
        if (not self._terminal(qb_row)
                or qb_row['inspection_id'] != common[3]
                or (qb_row['actor_id'], qb_row['actor_revision'],
                    qb_row['family_id']) != common[:3]
                or qb.plan != installed.plan
                or type(qb_receipt) is not PrivateQbittorrentReceipt
                or qb_receipt.state not in {
                    'qbittorrent_config_installed',
                    'qbittorrent_config_already_installed'}
                or qb_receipt.containerState != 'qbittorrent_container_started'
                or qb_receipt.serviceState != 'qbittorrent_service_verified'):
            raise ValueError('media_archive_authority_unavailable')

        arr_rows = connection.execute(
            "SELECT * FROM media_arr_configurations WHERE preparation_id=? "
            "AND service_id IN ('sonarr','radarr') ORDER BY service_id",
            (preparation_id,)).fetchall()
        if (len(arr_rows) != 2
                or tuple(row['service_id'] for row in arr_rows)
                != ('radarr', 'sonarr')):
            raise ValueError('media_archive_authority_unavailable')
        arr_values = {}
        for row in arr_rows:
            payload = self.arr._validate_row(connection, row)
            receipt = payload.receipt
            service = row['service_id']
            if (not self._terminal(row) or row['inspection_id'] != common[3]
                    or (row['actor_id'], row['actor_revision'],
                        row['family_id']) != common[:3]
                    or payload.plan != installed.plan
                    or type(receipt) is not PrivateArrReceipt
                    or receipt.serviceId != service
                    or receipt.state not in {
                        service + '_config_installed',
                        service + '_config_already_installed'}
                    or receipt.containerState != service + '_container_started'
                    or receipt.serviceState != service + '_service_verified'
                    or not hmac.compare_digest(
                        payload.private.qbittorrentApiKey or '',
                        qb.private.apiKey)):
                raise ValueError('media_archive_authority_unavailable')
            arr_values[service] = (row, payload, receipt)

        private = {
            'jellyfin': PrivateMediaArchiveSourceCredential(
                serviceId='jellyfin', serviceRecordId=bootstrap['id'],
                serviceRevision=bootstrap['revision'],
                apiKey=jellyfin.readback.apiKey,
                serverId=jellyfin.readback.serverId),
            'sonarr': PrivateMediaArchiveSourceCredential(
                serviceId='sonarr', serviceRecordId=arr_values['sonarr'][0]['id'],
                serviceRevision=arr_values['sonarr'][0]['revision'],
                apiKey=arr_values['sonarr'][1].private.apiKey,
                containerId=arr_values['sonarr'][2].containerId),
            'radarr': PrivateMediaArchiveSourceCredential(
                serviceId='radarr', serviceRecordId=arr_values['radarr'][0]['id'],
                serviceRevision=arr_values['radarr'][0]['revision'],
                apiKey=arr_values['radarr'][1].private.apiKey,
                containerId=arr_values['radarr'][2].containerId),
            'qbittorrent': PrivateMediaArchiveSourceCredential(
                serviceId='qbittorrent', serviceRecordId=qb_row['id'],
                serviceRevision=qb_row['revision'], apiKey=qb.private.apiKey,
                containerId=qb_receipt.containerId),
        }
        fingerprint = _digest({
            'installationId': installation_id,
            'installationRevision': installation['revision'],
            'planHash': installed.plan.planHash,
            'sources': [{
                'serviceId': service,
                'serviceRecordId': private[service].serviceRecordId,
                'serviceRevision': private[service].serviceRevision,
                'serverId': private[service].serverId,
                'containerId': private[service].containerId,
            } for service in _ORDER],
        })
        return _ResolvedArchiveSource(
            installation['revision'], fingerprint, installed.plan,
            tuple(private[service] for service in _ORDER))

    @staticmethod
    def _row_values(row):
        return {
            'installation_id': row['installation_id'],
            'snapshot_revision': row['snapshot_revision'],
            'installation_revision': row['installation_revision'],
            'state': row['state'],
            'source_fingerprint': row['source_fingerprint'],
            'observed_at': row['observed_at'],
            'retired_at': row['retired_at'],
            'observation_json': row['observation_json'],
        }

    @classmethod
    def _observation(cls, row):
        values = cls._row_values(row)
        if (type(row['digest']) is not str
                or type(row['source_fingerprint']) is not str
                or _DIGEST.fullmatch(row['digest']) is None
                or _DIGEST.fullmatch(row['source_fingerprint']) is None
                or not hmac.compare_digest(row['digest'], _digest(values))):
            raise ValueError('media_archive_snapshot_unavailable')
        observation = MediaArchiveObservation.model_validate_json(
            row['observation_json'])
        sources = (observation.jellyfin, observation.sonarr,
                   observation.radarr, observation.qbittorrent)
        if (row['state'] not in {'active', 'retired'}
                or any(item.installationId != row['installation_id']
                       or item.installationRevision
                       != row['installation_revision']
                       or item.snapshotRevision != row['snapshot_revision']
                       or item.observedAt != row['observed_at']
                       for item in sources)):
            raise ValueError('media_archive_snapshot_unavailable')
        return observation

    @staticmethod
    def _authority(observation):
        sources = (observation.jellyfin, observation.sonarr,
                   observation.radarr, observation.qbittorrent)
        first = sources[0]
        return MediaArchiveCollectionAuthority(
            installationId=first.installationId,
            installationRevision=first.installationRevision,
            snapshotRevision=first.snapshotRevision,
            sources=[ArchiveSourceBinding.model_validate(
                item.model_dump(include=_BINDING_FIELDS, mode='python'))
                for item in sources])

    def _active(self, connection, installation_id):
        row = connection.execute(
            "SELECT * FROM media_archive_snapshots "
            "WHERE installation_id=? AND state='active'",
            (installation_id,)).fetchone()
        return None if row is None else (row, self._observation(row))

    @staticmethod
    def _fresh(row, observation, resolved, now):
        observed_sources = (
            observation.jellyfin, observation.sonarr,
            observation.radarr, observation.qbittorrent)
        return (row['installation_revision'] == resolved.installation_revision
                and hmac.compare_digest(
                    row['source_fingerprint'], resolved.fingerprint)
                and all(
                    observed.serviceId == current.serviceId
                    and observed.serviceRecordId == current.serviceRecordId
                    and observed.serviceRevision == current.serviceRevision
                    for observed, current in zip(
                        observed_sources, resolved.sources, strict=True))
                and row['observed_at'] <= now
                and now - row['observed_at'] <= _REFRESH_SECONDS)

    def _retire(self, connection, installation_id, now):
        row = connection.execute(
            "SELECT * FROM media_archive_snapshots "
            "WHERE installation_id=? AND state='active'",
            (installation_id,)).fetchone()
        if row is not None:
            retired_at = max(now, row['observed_at'])
            values = self._row_values(row)
            values.update(state='retired', retired_at=retired_at)
            connection.execute(
                "UPDATE media_archive_snapshots SET "
                "state='retired',retired_at=?,digest=? "
                "WHERE installation_id=? AND state='active'",
                (retired_at, _digest(values), installation_id))

    @staticmethod
    def _same_resolution(left, right):
        if (left.installation_revision != right.installation_revision
                or not hmac.compare_digest(left.fingerprint, right.fingerprint)
                or left.plan != right.plan
                or len(left.sources) != len(right.sources)):
            return False
        for selected, current in zip(left.sources, right.sources, strict=True):
            if (selected.serviceId != current.serviceId
                    or selected.serviceRecordId != current.serviceRecordId
                    or selected.serviceRevision != current.serviceRevision
                    or selected.serverId != current.serverId
                    or selected.containerId != current.containerId
                    or not hmac.compare_digest(selected.apiKey, current.apiKey)):
                return False
        return True

    def _retained(self, installation_id, selected, deadline):
        if time.monotonic() >= deadline:
            return False
        try:
            with self.db.connection() as connection:
                connection.execute('BEGIN')
                current = self._resolve(connection, installation_id)
            return self._same_resolution(current, selected)
        except Exception:
            return False

    @staticmethod
    def _matches(authority, observation):
        returned = {item.serviceId: ArchiveSourceBinding.model_validate(
            item.model_dump(include=_BINDING_FIELDS, mode='python'))
            for item in (observation.jellyfin, observation.sonarr,
                         observation.radarr, observation.qbittorrent)}
        return returned == {item.serviceId: item for item in authority.sources}

    def _refresh(self, installation_id, resolved, now):
        with self.db.transaction() as connection:
            active = self._active(connection, installation_id)
            if active is not None and self._fresh(
                    active[0], active[1], resolved, now):
                return self._authority(active[1])
            revision = connection.execute(
                'SELECT COALESCE(MAX(snapshot_revision),0)+1 '
                'FROM media_archive_snapshots WHERE installation_id=?',
                (installation_id,)).fetchone()[0]
        authority = MediaArchiveCollectionAuthority(
            installationId=installation_id,
            installationRevision=resolved.installation_revision,
            snapshotRevision=revision,
            sources=[ArchiveSourceBinding(
                serviceId=source.serviceId,
                serviceRecordId=source.serviceRecordId,
                serviceRevision=source.serviceRevision,
                snapshotRevision=revision,
                installationId=installation_id,
                installationRevision=resolved.installation_revision,
                state='verified', observedAt=now)
                for source in resolved.sources])
        private = PrivateMediaArchiveWorkerCollection(
            requestId=uuid.uuid4().hex,
            authority=authority, plan=resolved.plan,
            sources=list(resolved.sources))
        deadline = time.monotonic() + 5
        gate = lambda: self._retained(
            installation_id, resolved, deadline)
        if gate() is not True:
            raise ValueError('media_archive_authority_changed')
        observed = self.backend.read_media_archive(
            private, deadline=deadline, gate=gate)
        if (time.monotonic() >= deadline or gate() is not True
                or type(observed) is not MediaArchiveObservation):
            raise ValueError('media_archive_worker_unavailable')
        observation = MediaArchiveObservation.model_validate(
            observed.model_dump(mode='python'))
        if not self._matches(authority, observation):
            raise ValueError('media_archive_authority_changed')
        observation_json = observation.model_dump_json()
        with self.db.transaction() as connection:
            current = self._resolve(connection, installation_id)
            if not self._same_resolution(current, resolved):
                raise ValueError('media_archive_authority_changed')
            active = self._active(connection, installation_id)
            if active is not None:
                if self._fresh(
                        active[0], active[1], current,
                        int(self.settings.clock())):
                    return self._authority(active[1])
                self._retire(connection, installation_id, now)
            expected = connection.execute(
                'SELECT COALESCE(MAX(snapshot_revision),0)+1 '
                'FROM media_archive_snapshots WHERE installation_id=?',
                (installation_id,)).fetchone()[0]
            if expected != revision:
                raise ValueError('media_archive_authority_changed')
            values = {
                'installation_id': installation_id,
                'snapshot_revision': revision,
                'installation_revision': resolved.installation_revision,
                'state': 'active',
                'source_fingerprint': resolved.fingerprint,
                'observed_at': now,
                'retired_at': None,
                'observation_json': observation_json,
            }
            connection.execute('''INSERT INTO media_archive_snapshots(
                installation_id,snapshot_revision,installation_revision,state,
                source_fingerprint,observed_at,retired_at,observation_json,digest
                ) VALUES(?,?,?,?,?,?,?,?,?)''',
                (*values.values(), _digest(values)))
            connection.execute('''DELETE FROM media_archive_snapshots
                WHERE installation_id=? AND state='retired'
                  AND snapshot_revision NOT IN (
                    SELECT snapshot_revision FROM media_archive_snapshots
                    WHERE installation_id=? ORDER BY snapshot_revision DESC
                    LIMIT ?)''',
                (installation_id, installation_id, _MAX_SNAPSHOTS - 1))
        return authority

    def current(self, installation_id):
        now = int(self.settings.clock())
        if now < 1:
            raise ValueError('media_archive_authority_unavailable')
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            resolved = self._resolve(connection, installation_id)
            active = self._active(connection, installation_id)
        if (active is not None
                and self._fresh(active[0], active[1], resolved, now)):
            return self._authority(active[1])
        return self._refresh(installation_id, resolved, now)

    def read_media_archive(self, private, *, deadline, gate):
        if (type(private) is not PrivateMediaArchiveCollection
                or type(deadline) not in (int, float) or type(deadline) is bool
                or not callable(gate) or time.monotonic() >= deadline):
            raise ValueError('media_archive_worker_unavailable')
        if gate() is not True:
            raise ValueError('media_archive_authority_changed')
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            resolved = self._resolve(
                connection, private.authority.installationId)
            active = self._active(
                connection, private.authority.installationId)
        if (active is None or not self._fresh(
                active[0], active[1], resolved, int(self.settings.clock()))
                or self._authority(active[1]) != private.authority
                or gate() is not True or time.monotonic() >= deadline):
            raise ValueError('media_archive_authority_changed')
        return active[1]

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    'SELECT * FROM media_archive_snapshots '
                    'ORDER BY installation_id,snapshot_revision').fetchall()
                counts = {}
                for row in rows:
                    counts[row['installation_id']] = (
                        counts.get(row['installation_id'], 0) + 1)
                    if counts[row['installation_id']] > _MAX_SNAPSHOTS:
                        raise ValueError()
                    self._observation(row)
        except (ApiError, ValidationError, ValueError, TypeError, sqlite3.Error,
                OverflowError, RecursionError):
            raise StartupError('invalid_media_archive_snapshots_storage') from None
