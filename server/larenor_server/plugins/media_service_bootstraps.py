"""Durable, encrypted S06.5 bootstrap intent without network side effects."""

from dataclasses import dataclass
import json
import re
import secrets
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..admin.service import utc
from ..errors import ApiError, StartupError
from .media_service_bootstrap_models import (
    CreateMediaServiceBootstrapRequest, MediaServiceBootstrap,
    PrivateMediaServiceBootstrap,
)


MAX_BOOTSTRAPS = 256
MAX_CIPHERTEXT = 32768
_BINDING = ('id', 'sequence', 'revision', 'actor_id', 'actor_revision', 'family_id',
            'request_id', 'installation_id', 'installation_revision', 'state',
            'credentials_configured', 'wiring_state', 'created_at', 'updated_at')


@dataclass(frozen=True, repr=False)
class _PrivateView:
    username: str
    credential: str
    locale: str
    remote_access: bool
    automatic_port_mapping: bool

    def __repr__(self):
        return '_PrivateView(<private>)'


def _identifier(value):
    if type(value) is not str or re.fullmatch(r'[0-9a-f]{32}', value) is None:
        raise ApiError('invalid_request')


def _request(value):
    try:
        if isinstance(value, CreateMediaServiceBootstrapRequest):
            return CreateMediaServiceBootstrapRequest.model_validate(
                value.model_dump(mode='python'))
        return CreateMediaServiceBootstrapRequest.model_validate(value)
    except (ValidationError, ValueError, TypeError, AttributeError):
        raise ApiError('invalid_request') from None


class MediaServiceBootstrapManagement:
    def __init__(self, db, auth, settings, key, installations):
        self.db, self.auth, self.settings = db, auth, settings
        self.installations = installations
        self._cipher = AESGCM(key)

    @staticmethod
    def _aad(row):
        binding = {key: row[key] for key in _BINDING}
        return b'larenor:media-service-bootstraps:schema=1:' + json.dumps(
            binding, sort_keys=True, separators=(',', ':')).encode('ascii')

    def _assert_admin(self, connection, actor):
        self.auth.assert_current(connection, actor)
        if actor.must_change_password:
            raise ApiError('password_change_required', 403)
        if actor.role != 'admin':
            raise ApiError('forbidden', 403)
        row = connection.execute('SELECT revision FROM users WHERE id=?', (actor.id,)).fetchone()
        if row is None:
            raise ApiError('invalid_token', 401)
        return row['revision']

    def _decode(self, row):
        try:
            if (len(row['nonce']) != 12 or len(row['ciphertext']) > MAX_CIPHERTEXT
                    or row['revision'] < 1 or row['actor_revision'] < 1
                    or row['installation_revision'] < 1
                    or any(re.fullmatch(r'[0-9a-f]{32}', row[key]) is None
                           for key in ('id', 'actor_id', 'family_id', 'request_id', 'installation_id'))):
                raise ValueError()
            raw = self._cipher.decrypt(row['nonce'], row['ciphertext'], self._aad(row))
            return PrivateMediaServiceBootstrap.model_validate_json(raw)
        except (InvalidTag, ValidationError, ValueError, TypeError):
            raise ApiError('media_bootstrap_storage_unavailable', 503) from None

    @staticmethod
    def _public(row):
        try:
            return MediaServiceBootstrap.model_validate({
                'id': row['id'], 'requestId': row['request_id'],
                'installationId': row['installation_id'], 'serviceId': 'jellyfin',
                'revision': row['revision'], 'state': row['state'],
                'credentialsConfigured': bool(row['credentials_configured']),
                'wiringState': row['wiring_state'], 'installAvailable': False,
                'createdAt': utc(row['created_at']), 'updatedAt': utc(row['updated_at']),
            }).model_dump()
        except (ValidationError, ValueError, TypeError):
            raise ApiError('media_bootstrap_storage_unavailable', 503) from None

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    'SELECT * FROM media_service_bootstraps ORDER BY sequence LIMIT ?',
                    (MAX_BOOTSTRAPS + 1,)).fetchall()
                if len(rows) > MAX_BOOTSTRAPS:
                    raise ApiError('media_bootstrap_storage_unavailable', 503)
                for row in rows:
                    self._validate_row(connection, row)
        except ApiError:
            raise StartupError('invalid_media_service_bootstraps_storage') from None

    def create(self, actor, body):
        body = _request(body)
        with self.db.transaction() as connection:
            actor_revision = self._assert_admin(connection, actor)
            previous = connection.execute(
                'SELECT * FROM media_service_bootstraps WHERE actor_id=? AND request_id=?',
                (actor.id, body.requestId)).fetchone()
            if previous is not None:
                self._validate_row(connection, previous)
                if (previous['family_id'] != actor.family_id
                        or previous['actor_revision'] != actor_revision
                        or previous['installation_id'] != body.installationId
                        or previous['installation_revision'] != body.expectedInstallationRevision):
                    raise ApiError('media_bootstrap_conflict', 409)
                return {'bootstrap': self._public(previous)}
            installation = connection.execute(
                'SELECT * FROM media_installations WHERE id=?', (body.installationId,)).fetchone()
            if installation is None:
                raise ApiError('not_found', 404)
            self.installations._decode(installation)
            if (installation['revision'] != body.expectedInstallationRevision
                    or installation['state'] != 'container_started'
                    or installation['phase'] != 'complete'
                    or installation['actor_id'] != actor.id
                    or installation['family_id'] != actor.family_id
                    or installation['actor_revision'] != actor_revision):
                raise ApiError('media_installation_changed', 409)
            if connection.execute(
                    'SELECT 1 FROM media_service_bootstraps WHERE installation_id=?',
                    (body.installationId,)).fetchone() is not None:
                raise ApiError('media_bootstrap_conflict', 409)
            if connection.execute(
                    'SELECT COUNT(*) FROM media_service_bootstraps').fetchone()[0] >= MAX_BOOTSTRAPS:
                raise ApiError('media_bootstrap_limit_reached', 409)
            now = int(self.settings.clock())
            row = {
                'id': uuid.uuid4().hex,
                'sequence': connection.execute(
                    'SELECT COALESCE(MAX(sequence),0)+1 FROM media_service_bootstraps').fetchone()[0],
                'revision': 1, 'actor_id': actor.id, 'actor_revision': actor_revision,
                'family_id': actor.family_id, 'request_id': body.requestId,
                'installation_id': body.installationId,
                'installation_revision': body.expectedInstallationRevision,
                'state': 'queued', 'credentials_configured': 0,
                'wiring_state': 'pending', 'created_at': now, 'updated_at': now,
            }
            private = PrivateMediaServiceBootstrap(
                credential=secrets.token_urlsafe(48),
            )
            nonce = secrets.token_bytes(12)
            ciphertext = self._cipher.encrypt(
                nonce, private.model_dump_json().encode('utf-8'), self._aad(row))
            connection.execute(
                'INSERT INTO media_service_bootstraps(' + ','.join(_BINDING)
                + ',nonce,ciphertext) VALUES(' + ','.join('?' for _ in range(len(_BINDING) + 2)) + ')',
                (*[row[key] for key in _BINDING], nonce, ciphertext))
            stored = connection.execute(
                'SELECT * FROM media_service_bootstraps WHERE id=?', (row['id'],)).fetchone()
            self._validate_row(connection, stored)
            return {'bootstrap': self._public(stored)}

    def _validate_row(self, connection, row):
        private = self._decode(row)
        self._public(row)
        installation = connection.execute(
            'SELECT * FROM media_installations WHERE id=?', (row['installation_id'],)).fetchone()
        if installation is None:
            raise ApiError('media_bootstrap_storage_unavailable', 503)
        try:
            self.installations._decode(installation)
        except ApiError:
            raise ApiError('media_bootstrap_storage_unavailable', 503) from None
        if (installation['revision'] != row['installation_revision']
                or installation['state'] != 'container_started'
                or installation['phase'] != 'complete'
                or installation['actor_id'] != row['actor_id']
                or installation['actor_revision'] != row['actor_revision']
                or installation['family_id'] != row['family_id']):
            raise ApiError('media_bootstrap_storage_unavailable', 503)
        return private

    def _find(self, connection, identifier):
        row = connection.execute(
            'SELECT * FROM media_service_bootstraps WHERE id=?', (identifier,)).fetchone()
        if row is None:
            raise ApiError('not_found', 404)
        self._validate_row(connection, row)
        return row

    def get(self, actor, identifier):
        _identifier(identifier)
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_admin(connection, actor)
            return {'bootstrap': self._public(self._find(connection, identifier))}

    def list(self, actor, *, before=None, limit=10):
        if (type(limit) is not int or not 1 <= limit <= 10
                or before is not None and (type(before) is not int or not 1 <= before <= 2**63 - 1)):
            raise ApiError('invalid_request')
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_admin(connection, actor)
            rows = connection.execute(
                'SELECT * FROM media_service_bootstraps WHERE sequence<? ORDER BY sequence DESC LIMIT ?',
                (before or 2**63 - 1, limit + 1)).fetchall()
            for row in rows:
                self._decode(row)
            return {'bootstraps': [self._public(row) for row in rows[:limit]],
                    'nextBefore': rows[limit - 1]['sequence'] if len(rows) > limit else None}

    def private_payload(self, identifier):
        """Trusted packaged worker seam; credentials never cross an HTTP model."""
        _identifier(identifier)
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            private = self._decode(self._find(connection, identifier))
            return _PrivateView(
                username=private.username, credential=private.credential,
                locale=private.locale, remote_access=private.remote_access,
                automatic_port_mapping=private.automatic_port_mapping,
            )
