"""Authenticated readiness and automatic peer wiring for managed Music Assistant.

The HTTP surface only reads redacted state. A packaged worker may record an
authenticated `info` readback through the private method after creating the
Music Assistant access token. The endpoint and token never enter an HTTP model.
"""

import hashlib
import re
import secrets

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..errors import ApiError, StartupError
from ..admin.service import utc
from .music_assistant_core_models import (
    AuthenticatedMusicAssistantReadback, MusicAssistantCoreReadiness,
    _StoredMusicAssistantCore,
)


MAX_RECORDS = 256
MAX_CIPHERTEXT = 16384


def managed_music_service_id(installation_id):
    return hashlib.sha256(
        ('larenor:managed-music-assistant:' + installation_id).encode('ascii')
    ).hexdigest()[:32]


class MusicAssistantCoreManagement:
    def __init__(self, db, auth, settings, key, installations, services):
        self.db, self.auth, self.settings = db, auth, settings
        self.installations, self.services = installations, services
        self._cipher = AESGCM(key)

    @staticmethod
    def _identity(value):
        if not isinstance(value, str) or re.fullmatch(r'[0-9a-f]{32}', value) is None:
            raise ApiError('invalid_request')

    @staticmethod
    def _aad(row):
        return ('larenor:music-assistant-core:schema=1:installation='
                + row['installation_id'] + ':installation-revision='
                + str(row['installation_revision']) + ':revision='
                + str(row['revision'])).encode('ascii')

    def _decode(self, row):
        try:
            self._identity(row['installation_id'])
            if (type(row['installation_revision']) is not int
                    or type(row['revision']) is not int
                    or row['installation_revision'] < 1 or row['revision'] < 1
                    or len(row['nonce']) != 12
                    or len(row['ciphertext']) > MAX_CIPHERTEXT):
                raise ValueError()
            raw = self._cipher.decrypt(
                row['nonce'], row['ciphertext'], self._aad(row))
            return _StoredMusicAssistantCore.model_validate_json(raw)
        except (ApiError, InvalidTag, ValidationError, ValueError, TypeError):
            raise ApiError('music_assistant_core_storage_unavailable', 503) from None

    def _assert_admin(self, connection, actor):
        self.auth.assert_current(connection, actor)
        if actor.must_change_password:
            raise ApiError('password_change_required', 403)
        if actor.role != 'admin':
            raise ApiError('forbidden', 403)

    def _installation(self, connection, installation_id, installation_revision):
        self._identity(installation_id)
        if type(installation_revision) is not int or installation_revision < 1:
            raise ApiError('invalid_request')
        row = connection.execute(
            'SELECT * FROM media_installations WHERE id=?', (installation_id,)).fetchone()
        if row is None:
            raise ApiError('not_found', 404)
        try:
            payload = self.installations._decode(row)
        except ApiError:
            raise ApiError('music_assistant_installation_changed', 409) from None
        if (row['revision'] != installation_revision
                or row['state'] != 'container_started'
                or row['phase'] != 'complete'
                or payload.request.serviceId != 'music_assistant'):
            raise ApiError('music_assistant_installation_changed', 409)
        return row

    def _discover_one(self, connection, kind):
        matches = []
        for row in connection.execute(
                'SELECT * FROM service_connections ORDER BY id LIMIT ?',
                (129,)).fetchall():
            record = self.services._decode(row)
            if record['kind'] != kind:
                continue
            credentials = set(record['credentials'])
            expected = credentials == {'token'} if kind == 'home_assistant' else credentials in ({'token'}, {'apiKey'})
            if record['verification']['state'] == 'authenticated' and expected:
                matches.append({'serviceId': row['id'], 'serviceRevision': row['revision']})
        if len(matches) > 1:
            raise ApiError('music_assistant_wiring_ambiguous', 409)
        if len(matches) != 1:
            raise ApiError('music_assistant_dependency_unverified', 409)
        return matches[0]

    def _dependency_current(self, connection, peer, kind):
        row = connection.execute(
            'SELECT * FROM service_connections WHERE id=?',
            (peer.serviceId,)).fetchone()
        if row is None or row['revision'] != peer.serviceRevision:
            return False
        try:
            record = self.services._decode(row)
        except ApiError:
            return False
        return record['kind'] == kind and record['verification']['state'] == 'authenticated'

    def _public(self, connection, row, stored):
        installation = connection.execute(
            'SELECT * FROM media_installations WHERE id=?',
            (row['installation_id'],)).fetchone()
        installation_current = False
        if installation is not None and installation['revision'] == row['installation_revision']:
            try:
                payload = self.installations._decode(installation)
                installation_current = (
                    installation['state'] == 'container_started'
                    and installation['phase'] == 'complete'
                    and payload.request.serviceId == 'music_assistant')
            except ApiError:
                pass
        dependency_current = (
            self._dependency_current(connection, stored.homeAssistant, 'home_assistant')
            and self._dependency_current(connection, stored.jellyfin, 'jellyfin'))
        error = None if installation_current and dependency_current else (
            'installation_changed' if not installation_current else 'dependency_changed')
        value = {
            'installationId': row['installation_id'],
            'installationRevision': row['installation_revision'],
            'revision': row['revision'],
            'state': 'verified' if error is None else 'needs_attention',
            'serverVersion': stored.serverVersion,
            'schemaVersion': stored.schemaVersion,
            'homeAssistant': stored.homeAssistant.model_dump(),
            'jellyfin': stored.jellyfin.model_dump(),
            'errorCode': error,
            'installAvailable': False,
        }
        return MusicAssistantCoreReadiness.model_validate(value).model_dump()

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    'SELECT * FROM music_assistant_core LIMIT ?',
                    (MAX_RECORDS + 1,)).fetchall()
                if len(rows) > MAX_RECORDS:
                    raise ApiError('music_assistant_core_storage_unavailable', 503)
                for row in rows:
                    self._decode(row)
        except ApiError:
            raise StartupError('invalid_music_assistant_core_storage') from None

    def record_authenticated_readback(self, installation_id, installation_revision, readback):
        if type(readback) is not AuthenticatedMusicAssistantReadback:
            raise ApiError('invalid_music_assistant_readback')
        with self.db.transaction() as connection:
            self._installation(connection, installation_id, installation_revision)
            service_id = managed_music_service_id(installation_id)
            service_row = connection.execute(
                'SELECT * FROM service_connections WHERE id=?',
                (service_id,)).fetchone()
            service_record = {
                'name': 'Larenor Music Assistant',
                'kind': 'music_assistant',
                'baseUrl': 'http://127.0.0.1:8095',
                'credentials': {'token': readback.token},
                'verification': {
                    'state': 'authenticated',
                    'checkedAt': utc(self.settings.clock()),
                    'version': readback.serverVersion}}
            if service_row is None:
                if connection.execute(
                        'SELECT COUNT(*) FROM service_connections').fetchone()[0] >= 128:
                    raise ApiError('service_limit_reached', 409)
                self.services._save(connection, service_id, 1, service_record)
            else:
                saved_service = self.services._decode(service_row)
                if (service_row['revision'] != 1
                        or {key: saved_service[key] for key in (
                            'name', 'kind', 'baseUrl', 'credentials')}
                        != {key: service_record[key] for key in (
                            'name', 'kind', 'baseUrl', 'credentials')}
                        or saved_service['verification']['state']
                        != 'authenticated'
                        or saved_service['verification']['version']
                        != readback.serverVersion):
                    raise ApiError('music_assistant_readback_conflict', 409)
            existing = connection.execute(
                'SELECT * FROM music_assistant_core WHERE installation_id=?',
                (installation_id,)).fetchone()
            if existing is not None:
                stored = self._decode(existing)
                if stored.model_dump() != {
                        **readback.model_dump(),
                        'homeAssistant': stored.homeAssistant.model_dump(),
                        'jellyfin': stored.jellyfin.model_dump()}:
                    raise ApiError('music_assistant_readback_conflict', 409)
                return self._public(connection, existing, stored)
            if connection.execute(
                    'SELECT COUNT(*) FROM music_assistant_core').fetchone()[0] >= MAX_RECORDS:
                raise ApiError('music_assistant_core_limit_reached', 409)
            stored = _StoredMusicAssistantCore(
                **readback.model_dump(),
                homeAssistant=self._discover_one(connection, 'home_assistant'),
                jellyfin=self._discover_one(connection, 'jellyfin'))
            now = int(self.settings.clock())
            row = {'installation_id': installation_id,
                   'installation_revision': installation_revision,
                   'revision': 1, 'created_at': now, 'updated_at': now}
            nonce = secrets.token_bytes(12)
            ciphertext = self._cipher.encrypt(
                nonce, stored.model_dump_json().encode('utf-8'), self._aad(row))
            connection.execute(
                'INSERT INTO music_assistant_core('
                'installation_id,installation_revision,revision,created_at,updated_at,nonce,ciphertext'
                ') VALUES(?,?,?,?,?,?,?)',
                (installation_id, installation_revision, 1, now, now, nonce, ciphertext))
            saved = connection.execute(
                'SELECT * FROM music_assistant_core WHERE installation_id=?',
                (installation_id,)).fetchone()
            return self._public(connection, saved, self._decode(saved))

    def get(self, actor, installation_id):
        self._identity(installation_id)
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_admin(connection, actor)
            row = connection.execute(
                'SELECT * FROM music_assistant_core WHERE installation_id=?',
                (installation_id,)).fetchone()
            if row is None:
                raise ApiError('not_found', 404)
            return {'readiness': self._public(connection, row, self._decode(row))}
