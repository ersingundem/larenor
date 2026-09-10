"""Encrypted, user-managed onboarding over upstream Music Assistant setup flows."""

import re
import secrets
import uuid
from urllib.parse import urlsplit

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..admin.service import utc
from ..errors import ApiError, StartupError
from .music_provider_setup_models import (
    CreateMusicProviderSetupRequest, MusicProviderSetup,
    ProviderSetupDiscovery, _StoredMusicProviderSetup,
)


MAX_SETUPS = 256
MAX_CIPHERTEXT = 32768
_BINDING = ('id', 'sequence', 'revision', 'actor_id', 'actor_revision',
            'family_id', 'installation_id', 'installation_revision', 'state',
            'created_at', 'updated_at')
_CAPABILITIES = [
    {'providerDomain': 'spotify', 'name': 'Spotify', 'stage': 'stable',
     'multiInstance': True, 'interaction': 'oauth_and_playback_approval'},
    {'providerDomain': 'apple_music', 'name': 'Apple Music', 'stage': 'stable',
     'multiInstance': True, 'interaction': 'musickit_or_secure_manual_token'},
    {'providerDomain': 'ytmusic', 'name': 'YouTube Music', 'stage': 'beta',
     'multiInstance': True, 'interaction': 'secure_cookie_and_po_token_service'},
]


class MusicProviderSetupManagement:
    def __init__(self, db, auth, settings, key, installations, music_core):
        self.db, self.auth, self.settings = db, auth, settings
        self.installations, self.music_core = installations, music_core
        self._cipher = AESGCM(key)

    @staticmethod
    def _identity(value):
        if not isinstance(value, str) or re.fullmatch(r'[0-9a-f]{32}', value) is None:
            raise ApiError('invalid_request')

    @staticmethod
    def _aad(row):
        return ('larenor:music-provider-setups:schema=1:id=' + row['id']
                + ':sequence=' + str(row['sequence'])
                + ':revision=' + str(row['revision'])
                + ':actor=' + row['actor_id']
                + ':actor-revision=' + str(row['actor_revision'])
                + ':family=' + row['family_id']
                + ':installation=' + row['installation_id']
                + ':installation-revision=' + str(row['installation_revision'])
                + ':state=' + row['state']).encode('ascii')

    def _decode(self, row):
        try:
            if (len(row['nonce']) != 12 or len(row['ciphertext']) > MAX_CIPHERTEXT
                    or row['revision'] < 1 or row['sequence'] < 1
                    or row['actor_revision'] < 1 or row['installation_revision'] < 1):
                raise ValueError()
            for key in ('id', 'actor_id', 'family_id', 'installation_id'):
                self._identity(row[key])
            return _StoredMusicProviderSetup.model_validate_json(
                self._cipher.decrypt(row['nonce'], row['ciphertext'], self._aad(row)))
        except (ApiError, InvalidTag, ValidationError, ValueError, TypeError):
            raise ApiError('music_provider_setup_storage_unavailable', 503) from None

    def _assert_admin(self, connection, actor):
        self.auth.assert_current(connection, actor)
        if actor.must_change_password:
            raise ApiError('password_change_required', 403)
        if actor.role != 'admin':
            raise ApiError('forbidden', 403)
        row = connection.execute(
            'SELECT revision FROM users WHERE id=?', (actor.id,)).fetchone()
        if row is None:
            raise ApiError('invalid_token', 401)
        return row['revision']

    def _readiness(self, connection, installation_id, installation_revision):
        row = connection.execute(
            'SELECT * FROM music_assistant_core WHERE installation_id=?',
            (installation_id,)).fetchone()
        if row is None or row['installation_revision'] != installation_revision:
            raise ApiError('music_assistant_not_ready', 409)
        try:
            readiness = self.music_core._public(
                connection, row, self.music_core._decode(row))
        except ApiError:
            raise ApiError('music_assistant_not_ready', 409) from None
        if readiness['state'] != 'verified':
            raise ApiError('music_assistant_not_ready', 409)

    @staticmethod
    def _interaction(discovery):
        return 'open_external' if discovery.kind == 'external' else 'submit_form'

    @staticmethod
    def _validate_discovery(discovery):
        entries = [(entry.key, entry.type, entry.required)
                   for entry in discovery.entries]
        if discovery.providerDomain == 'spotify':
            parsed = urlsplit(discovery.externalUrl or '')
            valid = (discovery.kind == 'external'
                     and discovery.stepId == 'authenticate'
                     and parsed.hostname == 'accounts.spotify.com')
        elif discovery.providerDomain == 'apple_music':
            valid = (
                discovery.kind == 'form'
                and ((discovery.stepId == 'app_token'
                      and entries == [('music_app_token', 'secure_string', True)])
                     or (discovery.stepId == 'user'
                         and entries == [('music_user_manual_token',
                                          'secure_string', False)])))
        else:
            valid = (discovery.kind == 'form' and discovery.stepId == 'user'
                     and entries == [
                         ('username', 'string', True),
                         ('cookie', 'secure_string', True),
                         ('po_token_server_url', 'string', True),
                     ])
        if not valid:
            raise ApiError('music_provider_capability_changed', 409)

    def _public(self, row, stored):
        discovery = stored.discovery
        result = {
            'id': row['id'], 'requestId': stored.request.requestId,
            'installationId': row['installation_id'],
            'installationRevision': row['installation_revision'],
            'providerDomain': stored.request.providerDomain,
            'revision': row['revision'], 'state': row['state'],
            'nextAction': ('awaiting_core_discovery' if discovery is None
                           else 'continue_in_larenor'),
            'interaction': None if discovery is None else self._interaction(discovery),
            'fields': [] if discovery is None else [
                entry.model_dump() for entry in discovery.entries],
            'installAvailable': False,
            'createdAt': utc(row['created_at']), 'updatedAt': utc(row['updated_at']),
        }
        return MusicProviderSetup.model_validate(result).model_dump()

    def _save(self, connection, row, stored):
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(
            nonce, stored.model_dump_json().encode('utf-8'), self._aad(row))
        connection.execute(
            'UPDATE music_provider_setups SET '
            + ','.join(key + '=?' for key in _BINDING)
            + ',nonce=?,ciphertext=? WHERE id=?',
            (*[row[key] for key in _BINDING], nonce, ciphertext, row['id']))

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    'SELECT * FROM music_provider_setups LIMIT ?',
                    (MAX_SETUPS + 1,)).fetchall()
                if len(rows) > MAX_SETUPS:
                    raise ApiError('music_provider_setup_storage_unavailable', 503)
                for row in rows:
                    self._decode(row)
        except ApiError:
            raise StartupError('invalid_music_provider_setup_storage') from None

    def capabilities(self, actor):
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_admin(connection, actor)
            return {'installAvailable': False,
                    'setupEngine': 'music_assistant_setup_flow',
                    'providers': _CAPABILITIES}

    def create(self, actor, body):
        if type(body) is not CreateMusicProviderSetupRequest:
            raise ApiError('invalid_request')
        with self.db.transaction() as connection:
            actor_revision = self._assert_admin(connection, actor)
            self._readiness(
                connection, body.installationId,
                body.expectedInstallationRevision)
            rows = connection.execute(
                'SELECT * FROM music_provider_setups WHERE actor_id=? LIMIT ?',
                (actor.id, MAX_SETUPS + 1)).fetchall()
            if len(rows) > MAX_SETUPS:
                raise ApiError('music_provider_setup_storage_unavailable', 503)
            for previous in rows:
                stored = self._decode(previous)
                if stored.request.requestId != body.requestId:
                    continue
                if (stored.request != body
                        or previous['actor_revision'] != actor_revision
                        or previous['family_id'] != actor.family_id):
                    raise ApiError('music_provider_setup_conflict', 409)
                return {'setup': self._public(previous, stored)}
            if connection.execute(
                    'SELECT COUNT(*) FROM music_provider_setups').fetchone()[0] >= MAX_SETUPS:
                raise ApiError('music_provider_setup_limit_reached', 409)
            now = int(self.settings.clock())
            row = {
                'id': uuid.uuid4().hex,
                'sequence': connection.execute(
                    'SELECT COALESCE(MAX(sequence),0)+1 FROM music_provider_setups').fetchone()[0],
                'revision': 1, 'actor_id': actor.id,
                'actor_revision': actor_revision, 'family_id': actor.family_id,
                'installation_id': body.installationId,
                'installation_revision': body.expectedInstallationRevision,
                'state': 'queued', 'created_at': now, 'updated_at': now,
            }
            connection.execute(
                'INSERT INTO music_provider_setups(' + ','.join(_BINDING)
                + ',nonce,ciphertext) VALUES('
                + ','.join('?' for _ in range(len(_BINDING) + 2)) + ')',
                (*[row[key] for key in _BINDING], b'', b''))
            stored = _StoredMusicProviderSetup(request=body)
            self._save(connection, row, stored)
            saved = connection.execute(
                'SELECT * FROM music_provider_setups WHERE id=?',
                (row['id'],)).fetchone()
            return {'setup': self._public(saved, self._decode(saved))}

    def _find(self, connection, identifier):
        self._identity(identifier)
        row = connection.execute(
            'SELECT * FROM music_provider_setups WHERE id=?', (identifier,)).fetchone()
        if row is None:
            raise ApiError('not_found', 404)
        return row

    def get(self, actor, identifier):
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_admin(connection, actor)
            row = self._find(connection, identifier)
            return {'setup': self._public(row, self._decode(row))}

    def record_initial_discovery(self, identifier, expected_revision, discovery):
        if type(expected_revision) is not int or expected_revision < 1:
            raise ApiError('invalid_request')
        if type(discovery) is not ProviderSetupDiscovery:
            raise ApiError('invalid_provider_setup_discovery')
        with self.db.transaction() as connection:
            row = self._find(connection, identifier)
            stored = self._decode(row)
            if row['revision'] != expected_revision or row['state'] != 'queued':
                raise ApiError('revision_conflict', 409)
            self._readiness(
                connection, row['installation_id'], row['installation_revision'])
            if discovery.providerDomain != stored.request.providerDomain:
                raise ApiError('music_provider_capability_changed', 409)
            if discovery.expiresAt <= self.settings.clock():
                raise ApiError('music_provider_capability_changed', 409)
            self._validate_discovery(discovery)
            changed = dict(row)
            changed.update(revision=row['revision'] + 1,
                           state='action_required',
                           updated_at=max(row['updated_at'], int(self.settings.clock())))
            updated = _StoredMusicProviderSetup(
                request=stored.request, discovery=discovery)
            self._save(connection, changed, updated)
            saved = connection.execute(
                'SELECT * FROM music_provider_setups WHERE id=?',
                (identifier,)).fetchone()
            return self._public(saved, self._decode(saved))
