"""Authenticated readiness and automatic peer wiring for managed Music Assistant.

The HTTP surface only reads redacted state. A packaged worker may record an
authenticated `info` readback through the private method after creating the
Music Assistant access token. The endpoint and token never enter an HTTP model.
"""

import re
import secrets
import time

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..errors import ApiError, StartupError
from .music_assistant_core_models import (
    AuthenticatedMusicAssistantKeyRotationReadback,
    AuthenticatedMusicAssistantReadback, MusicAssistantCoreReadiness,
    MusicAssistantKeyRotationReceipt, MusicAssistantKeyRotationRequest,
    PrivateMusicAssistantKeyRotationAction,
    _StoredMusicAssistantCore, _StoredMusicAssistantKeyRotation,
)


MAX_RECORDS = 256
MAX_CIPHERTEXT = 16384
MAX_ROTATIONS = 512
MAX_ROTATION_CIPHERTEXT = 32768


class MusicAssistantCoreManagement:
    def __init__(self, db, auth, settings, key, installations, services):
        self.db, self.auth, self.settings = db, auth, settings
        self.installations, self.services = installations, services
        self._cipher = AESGCM(key)
        self.provider_setups = None

    def attach_provider_setups(self, provider_setups):
        if self.provider_setups is not None or provider_setups.music_core is not self:
            raise StartupError('invalid_music_assistant_core_storage')
        self.provider_setups = provider_setups

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
        row = connection.execute(
            'SELECT revision FROM users WHERE id=?', (actor.id,)).fetchone()
        if row is None:
            raise ApiError('invalid_session', 401)
        return row['revision']

    @staticmethod
    def _rotation_aad(row):
        keys = (
            'request_id', 'sequence', 'state', 'actor_id', 'actor_revision',
            'family_id', 'core_id', 'home_id', 'installation_id',
            'installation_revision', 'worker_revision', 'provider_setup_id',
            'provider_revision',
        )
        return ('larenor:music-assistant-key-rotation:schema=1:'
                + ':'.join(key.replace('_', '-') + '=' + str(row[key])
                           for key in keys)).encode('ascii')

    def _decode_rotation(self, row):
        try:
            for key in (
                    'request_id', 'actor_id', 'family_id', 'core_id',
                    'home_id', 'installation_id', 'provider_setup_id'):
                self._identity(row[key])
            if (any(type(row[key]) is not int or row[key] < 1 for key in (
                    'sequence', 'actor_revision', 'installation_revision',
                    'worker_revision', 'provider_revision'))
                    or row['state'] not in {'preparing', 'activated', 'retired'}
                    or len(row['nonce']) != 12
                    or len(row['ciphertext']) > MAX_ROTATION_CIPHERTEXT):
                raise ValueError()
            stored = _StoredMusicAssistantKeyRotation.model_validate_json(
                self._cipher.decrypt(
                    row['nonce'], row['ciphertext'], self._rotation_aad(row)))
            if (stored.request.requestId != row['request_id']
                    or stored.request.coreId != row['core_id']
                    or stored.request.homeId != row['home_id']
                    or stored.request.installationId != row['installation_id']
                    or stored.request.expectedInstallationRevision
                    != row['installation_revision']
                    or stored.request.expectedWorkerRevision
                    != row['worker_revision']
                    or stored.request.providerSetupId != row['provider_setup_id']
                    or stored.request.expectedProviderRevision
                    != row['provider_revision']):
                raise ValueError()
            if ((row['state'] == 'preparing') != (stored.replacement is None)):
                raise ValueError()
            return stored
        except (ApiError, InvalidTag, ValidationError, ValueError, TypeError):
            raise ApiError(
                'music_assistant_key_rotation_storage_unavailable', 503
            ) from None

    def _save_rotation(self, connection, row, stored):
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(
            nonce, stored.model_dump_json().encode('utf-8'),
            self._rotation_aad(row))
        values = tuple(row[key] for key in (
            'request_id', 'sequence', 'state', 'actor_id', 'actor_revision',
            'family_id', 'core_id', 'home_id', 'installation_id',
            'installation_revision', 'worker_revision', 'provider_setup_id',
            'provider_revision', 'created_at', 'updated_at'))
        connection.execute('''INSERT INTO music_assistant_key_rotations(
            request_id,sequence,state,actor_id,actor_revision,family_id,
            core_id,home_id,installation_id,installation_revision,
            worker_revision,provider_setup_id,provider_revision,created_at,
            updated_at,nonce,ciphertext) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(request_id) DO UPDATE SET
            state=excluded.state,updated_at=excluded.updated_at,
            nonce=excluded.nonce,ciphertext=excluded.ciphertext''',
                           (*values, nonce, ciphertext))

    def _provider(self, connection, request):
        if self.provider_setups is None:
            raise ApiError('music_assistant_key_rotation_unavailable', 503)
        row = connection.execute(
            'SELECT * FROM music_provider_setups WHERE id=?',
            (request.providerSetupId,)).fetchone()
        if (row is None or row['revision'] != request.expectedProviderRevision
                or row['installation_id'] != request.installationId
                or row['installation_revision']
                != request.expectedInstallationRevision):
            raise ApiError('music_assistant_key_rotation_authority_changed', 409)
        try:
            stored = self.provider_setups._decode(row)
        except ApiError:
            raise ApiError(
                'music_assistant_key_rotation_authority_changed', 409
            ) from None
        if (stored.status != 'ready'
                or stored.providerInstanceId != request.providerInstanceId):
            raise ApiError('music_assistant_key_rotation_authority_changed', 409)

    def _authority(self, connection, actor, request, worker_revision):
        actor_revision = self._assert_admin(connection, actor)
        context = connection.execute(
            'SELECT core_id,home_id FROM core_context WHERE singleton=1'
        ).fetchone()
        if (context is None or context['core_id'] != request.coreId
                or context['home_id'] != request.homeId):
            raise ApiError('music_assistant_key_rotation_authority_changed', 409)
        self._installation(
            connection, request.installationId,
            request.expectedInstallationRevision)
        core = connection.execute(
            'SELECT * FROM music_assistant_core WHERE installation_id=?',
            (request.installationId,)).fetchone()
        if core is None or core['revision'] != worker_revision:
            raise ApiError('music_assistant_key_rotation_authority_changed', 409)
        stored = self._decode(core)
        if self._public(connection, core, stored)['state'] != 'verified':
            raise ApiError('music_assistant_key_rotation_authority_changed', 409)
        self._provider(connection, request)
        return actor_revision, core, stored

    def _rotation_gate(self, actor, request_id, expected_state):
        try:
            with self.db.connection() as connection:
                connection.execute('BEGIN')
                row = connection.execute(
                    'SELECT * FROM music_assistant_key_rotations '
                    'WHERE request_id=?', (request_id,)).fetchone()
                if row is None or row['state'] != expected_state:
                    return False
                stored = self._decode_rotation(row)
                if (row['actor_id'] != actor.id
                        or row['family_id'] != actor.family_id
                        or self._assert_admin(connection, actor)
                        != row['actor_revision']):
                    return False
                worker_revision = row['worker_revision'] + (
                    1 if expected_state == 'activated' else 0)
                _revision, _core, current = self._authority(
                    connection, actor, stored.request, worker_revision)
                expected = (stored.previous if expected_state == 'preparing'
                            else stored.replacement)
                return expected is not None and current.token == expected.token
        except (ApiError, ValueError, TypeError):
            return False

    @staticmethod
    def _receipt(row, stored):
        return {'rotation': MusicAssistantKeyRotationReceipt(
            requestId=row['request_id'], installationId=row['installation_id'],
            installationRevision=row['installation_revision'],
            workerRevision=row['worker_revision'] + 1,
            providerSetupId=row['provider_setup_id'],
            providerRevision=row['provider_revision'],
            providerInstanceId=stored.request.providerInstanceId,
            state='retired').model_dump()}

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
                rotations = connection.execute(
                    'SELECT * FROM music_assistant_key_rotations LIMIT ?',
                    (MAX_ROTATIONS + 1,)).fetchall()
                if len(rotations) > MAX_ROTATIONS:
                    raise ApiError(
                        'music_assistant_key_rotation_storage_unavailable', 503)
                for row in rotations:
                    self._decode_rotation(row)
        except ApiError:
            raise StartupError('invalid_music_assistant_core_storage') from None

    def _begin_rotation(self, actor, request):
        with self.db.transaction() as connection:
            existing = connection.execute(
                'SELECT * FROM music_assistant_key_rotations '
                'WHERE request_id=?', (request.requestId,)).fetchone()
            if existing is not None:
                stored = self._decode_rotation(existing)
                actor_revision = self._assert_admin(connection, actor)
                if (stored.request != request
                        or existing['actor_id'] != actor.id
                        or existing['actor_revision'] != actor_revision
                        or existing['family_id'] != actor.family_id):
                    raise ApiError(
                        'music_assistant_key_rotation_conflict', 409)
                self._authority(
                    connection, actor, request,
                    request.expectedWorkerRevision
                    + (1 if existing['state'] != 'preparing' else 0))
                return existing, stored, False
            actor_revision, _core, previous = self._authority(
                connection, actor, request, request.expectedWorkerRevision)
            concurrent = connection.execute(
                "SELECT 1 FROM music_assistant_key_rotations "
                "WHERE installation_id=? AND state!='retired' LIMIT 1",
                (request.installationId,)).fetchone()
            if concurrent is not None:
                raise ApiError('music_assistant_key_rotation_conflict', 409)
            count = connection.execute(
                'SELECT COUNT(*) FROM music_assistant_key_rotations'
            ).fetchone()[0]
            if count >= MAX_ROTATIONS:
                raise ApiError(
                    'music_assistant_key_rotation_limit_reached', 409)
            now = int(self.settings.clock())
            row = {
                'request_id': request.requestId,
                'sequence': connection.execute(
                    'SELECT COALESCE(MAX(sequence),0)+1 '
                    'FROM music_assistant_key_rotations').fetchone()[0],
                'state': 'preparing', 'actor_id': actor.id,
                'actor_revision': actor_revision, 'family_id': actor.family_id,
                'core_id': request.coreId, 'home_id': request.homeId,
                'installation_id': request.installationId,
                'installation_revision': request.expectedInstallationRevision,
                'worker_revision': request.expectedWorkerRevision,
                'provider_setup_id': request.providerSetupId,
                'provider_revision': request.expectedProviderRevision,
                'created_at': now, 'updated_at': now,
            }
            stored = _StoredMusicAssistantKeyRotation(
                request=request, previous=previous)
            self._save_rotation(connection, row, stored)
            saved = connection.execute(
                'SELECT * FROM music_assistant_key_rotations '
                'WHERE request_id=?', (request.requestId,)).fetchone()
            return saved, self._decode_rotation(saved), True

    @staticmethod
    def _call_worker(backend, method, action, deadline, gate):
        callback = getattr(backend, method, None)
        if not callable(callback):
            raise ApiError('music_assistant_key_rotation_unavailable', 503)
        try:
            return callback(action, deadline=deadline, gate=gate)
        except Exception:
            raise ApiError(
                'music_assistant_key_rotation_uncertain', 503
            ) from None

    @staticmethod
    def _validate_readback(stored, result, *, retired):
        if (type(result) is not AuthenticatedMusicAssistantKeyRotationReadback
                or result.requestId != stored.request.requestId
                or result.previousTokenRetired is not retired
                or result.readback.serverId != stored.previous.serverId
                or result.readback.schemaVersion < stored.previous.schemaVersion
                or result.readback.token == stored.previous.token):
            raise ApiError('music_assistant_key_rotation_readback_changed', 409)
        if (stored.replacement is not None
                and stored.replacement != result.readback):
            raise ApiError('music_assistant_key_rotation_readback_changed', 409)
        return result.readback

    def _activate_rotation(self, actor, row, stored, result):
        replacement = self._validate_readback(stored, result, retired=False)
        with self.db.transaction() as connection:
            current = connection.execute(
                'SELECT * FROM music_assistant_key_rotations '
                'WHERE request_id=?', (row['request_id'],)).fetchone()
            if current is None or current['state'] != 'preparing':
                raise ApiError('music_assistant_key_rotation_conflict', 409)
            current_stored = self._decode_rotation(current)
            if current_stored != stored:
                raise ApiError('music_assistant_key_rotation_conflict', 409)
            _actor_revision, core, active = self._authority(
                connection, actor, stored.request, row['worker_revision'])
            if active != stored.previous:
                raise ApiError('music_assistant_key_rotation_conflict', 409)
            changed_core = dict(core)
            changed_core.update(
                revision=core['revision'] + 1,
                updated_at=max(core['updated_at'], int(self.settings.clock())))
            replaced = active.model_copy(update={
                'token': replacement.token,
                'serverVersion': replacement.serverVersion,
                'schemaVersion': replacement.schemaVersion,
            })
            nonce = secrets.token_bytes(12)
            ciphertext = self._cipher.encrypt(
                nonce, replaced.model_dump_json().encode('utf-8'),
                self._aad(changed_core))
            connection.execute(
                'UPDATE music_assistant_core SET revision=?,updated_at=?,nonce=?,'
                'ciphertext=? WHERE installation_id=? AND revision=?',
                (changed_core['revision'], changed_core['updated_at'], nonce,
                 ciphertext, core['installation_id'], core['revision']))
            changed = dict(current)
            changed.update(
                state='activated',
                updated_at=max(current['updated_at'], int(self.settings.clock())))
            final = current_stored.model_copy(update={'replacement': replacement})
            self._save_rotation(connection, changed, final)
            saved = connection.execute(
                'SELECT * FROM music_assistant_key_rotations '
                'WHERE request_id=?', (row['request_id'],)).fetchone()
            return saved, self._decode_rotation(saved)

    def _retire_rotation(self, actor, row, stored, result):
        self._validate_readback(stored, result, retired=True)
        with self.db.transaction() as connection:
            current = connection.execute(
                'SELECT * FROM music_assistant_key_rotations '
                'WHERE request_id=?', (row['request_id'],)).fetchone()
            if current is None or current['state'] != 'activated':
                raise ApiError('music_assistant_key_rotation_conflict', 409)
            current_stored = self._decode_rotation(current)
            if current_stored != stored:
                raise ApiError('music_assistant_key_rotation_conflict', 409)
            self._authority(
                connection, actor, stored.request, row['worker_revision'] + 1)
            changed = dict(current)
            changed.update(
                state='retired',
                updated_at=max(current['updated_at'], int(self.settings.clock())))
            self._save_rotation(connection, changed, current_stored)
            saved = connection.execute(
                'SELECT * FROM music_assistant_key_rotations '
                'WHERE request_id=?', (row['request_id'],)).fetchone()
            return self._receipt(saved, self._decode_rotation(saved))

    def rotate_key(self, actor, request, backend):
        """Rotate the private worker credential without exposing it to HTTP."""
        if type(request) is not MusicAssistantKeyRotationRequest:
            raise ApiError('invalid_request')
        row, stored, created = self._begin_rotation(actor, request)
        if row['state'] == 'retired':
            return self._receipt(row, stored)
        deadline = time.monotonic() + 15
        gate = lambda: self._rotation_gate(
            actor, request.requestId, row['state'])
        action = PrivateMusicAssistantKeyRotationAction(
            request=request, phase=row['state'],
            currentToken=stored.previous.token,
            replacementToken=(None if stored.replacement is None
                              else stored.replacement.token))
        if row['state'] == 'preparing':
            method = ('prepare_music_assistant_key_rotation' if created
                      else 'reconcile_music_assistant_key_rotation')
            result = self._call_worker(backend, method, action, deadline, gate)
            if result is None:
                raise ApiError('music_assistant_key_rotation_uncertain', 503)
            row, stored = self._activate_rotation(
                actor, row, stored, result)
            action = PrivateMusicAssistantKeyRotationAction(
                request=request, phase='activated',
                currentToken=stored.previous.token,
                replacementToken=stored.replacement.token)
            gate = lambda: self._rotation_gate(
                actor, request.requestId, 'activated')
            result = self._call_worker(
                backend, 'retire_music_assistant_key', action, deadline, gate)
        else:
            result = self._call_worker(
                backend, 'reconcile_music_assistant_key_rotation', action,
                deadline, gate)
        if result is None:
            raise ApiError('music_assistant_key_rotation_uncertain', 503)
        return self._retire_rotation(actor, row, stored, result)

    def record_authenticated_readback(self, installation_id, installation_revision, readback):
        if type(readback) is not AuthenticatedMusicAssistantReadback:
            raise ApiError('invalid_music_assistant_readback')
        with self.db.transaction() as connection:
            self._installation(connection, installation_id, installation_revision)
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
