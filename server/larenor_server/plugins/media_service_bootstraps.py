"""Durable, encrypted S06.5 bootstrap intent without network side effects."""

from dataclasses import dataclass
from contextlib import contextmanager
import fcntl
import json
import os
import re
import secrets
import stat
import time
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..admin.service import utc
from ..errors import ApiError, StartupError
from .media_service_bootstrap_models import (
    CreateMediaServiceBootstrapRequest, MediaServiceBootstrap,
    PrivateJellyfinReadback, PrivateMediaLibrary, PrivateMediaServiceBootstrap,
)
from .jellyfin_bootstrap_executor import (
    JellyfinBootstrapExecutionError, JellyfinBootstrapExecutionResult,
)
from .catalog import load_catalog
from .stack_plan import verify_media_stack_plan


MAX_BOOTSTRAPS = 256
MAX_CIPHERTEXT = 32768
_BINDING = ('id', 'sequence', 'revision', 'actor_id', 'actor_revision', 'family_id',
            'request_id', 'installation_id', 'installation_revision', 'state',
            'credentials_configured', 'wiring_state', 'error_code', 'created_at',
            'updated_at')


@dataclass(frozen=True, repr=False)
class _PrivateView:
    username: str
    credential: str
    locale: str
    remote_access: bool
    automatic_port_mapping: bool
    api_key: str | None
    server_id: str | None
    server_name: str | None
    version: str | None
    libraries: tuple[tuple[str, str | None, str, tuple[str, ...]], ...]

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
    def __init__(self, db, auth, settings, key, installations, backend=None):
        self.db, self.auth, self.settings = db, auth, settings
        self.installations = installations
        self.backend = backend
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
                'wiringState': row['wiring_state'], 'errorCode': row['error_code'],
                'installAvailable': False,
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
                'wiring_state': 'pending', 'error_code': None,
                'created_at': now, 'updated_at': now,
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
                api_key=None if private.readback is None else private.readback.apiKey,
                server_id=None if private.readback is None else private.readback.serverId,
                server_name=None if private.readback is None else private.readback.serverName,
                version=None if private.readback is None else private.readback.version,
                libraries=(() if private.readback is None else tuple(
                    (item.name, item.collectionType, item.itemId, item.locations)
                    for item in private.readback.libraries)),
            )

    def _save(self, connection, row, private):
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(
            nonce, private.model_dump_json().encode('utf-8'), self._aad(row))
        self._decode(dict(row) | {'nonce': nonce, 'ciphertext': ciphertext})
        connection.execute(
            'UPDATE media_service_bootstraps SET '
            + ','.join(key + '=?' for key in _BINDING)
            + ',nonce=?,ciphertext=? WHERE id=?',
            (*[row[key] for key in _BINDING], nonce, ciphertext, row['id']),
        )

    def _transition(self, connection, row, private, *, state, error=None):
        changed = dict(row)
        changed.update(
            revision=row['revision'] + 1,
            state=state,
            credentials_configured=int(state in {
                'credentials_configured', 'wiring_partial', 'succeeded'}),
            wiring_state=(
                'verified' if state == 'succeeded'
                else 'partial' if state == 'wiring_partial'
                else row['wiring_state']
            ),
            error_code=error,
            updated_at=max(row['updated_at'], int(self.settings.clock())),
        )
        self._save(connection, changed, private)
        return {'bootstrap': self._public(changed)}

    def _dispatch_authorized(self, connection, row):
        current = connection.execute(
            'SELECT u.revision,u.role,u.disabled,u.must_change_password,'
            'f.revoked_at,f.expires_at FROM users u JOIN session_families f '
            'ON f.user_id=u.id WHERE u.id=? AND f.id=?',
            (row['actor_id'], row['family_id']),
        ).fetchone()
        return bool(
            current and current['revision'] == row['actor_revision']
            and current['role'] == 'admin' and not current['disabled']
            and not current['must_change_password'] and current['revoked_at'] is None
            and current['expires_at'] > self.settings.clock()
        )

    def _execution_inputs(self, connection, row):
        private = self._validate_row(connection, row)
        installation = connection.execute(
            'SELECT * FROM media_installations WHERE id=?',
            (row['installation_id'],),
        ).fetchone()
        payload = self.installations._decode(installation)
        catalog = load_catalog()
        if catalog.digest != self.installations.preparations.plugins._catalog.digest:
            raise ValueError()
        plan = verify_media_stack_plan(payload.plan, catalog)
        return private, plan

    def _gate_locked(self, connection, row):
        if not self._dispatch_authorized(connection, row):
            return False
        try:
            _private, plan = self._execution_inputs(connection, row)
            return (plan.coreId == self.installations.preparations.context.coreId
                    and plan.homeId == self.installations.preparations.context.homeId)
        except (ApiError, ValueError, TypeError, AttributeError, OSError):
            return False

    def _gate(self, identifier):
        try:
            with self.db.connection() as connection:
                connection.execute('BEGIN')
                row = self._find(connection, identifier)
                return row['state'] == 'running' and self._gate_locked(connection, row)
        except (ApiError, ValueError, TypeError, AttributeError, OSError):
            return False

    @contextmanager
    def _dispatch_lock(self):
        descriptor = None
        try:
            descriptor = os.open(
                self.settings.data_dir / '.media-service-bootstraps.lock',
                os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
                0o600,
            )
            info = os.fstat(descriptor)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                raise ApiError('media_bootstrap_storage_unavailable', 503)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                yield False
                return
            yield True
        except OSError:
            raise ApiError('media_bootstrap_storage_unavailable', 503) from None
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def tick(self):
        with self._dispatch_lock() as acquired:
            if not acquired:
                return None
            with self.db.transaction() as connection:
                row = connection.execute(
                    "SELECT * FROM media_service_bootstraps WHERE state IN ('queued','running') "
                    "ORDER BY CASE state WHEN 'running' THEN 0 ELSE 1 END,sequence LIMIT 1",
                ).fetchone()
                if row is None:
                    return None
                private = self._decode(row)
                if row['state'] == 'running':
                    return self._transition(
                        connection, row, private, state='needs_attention',
                        error='bootstrap_interrupted',
                    )
                if not self._gate_locked(connection, row):
                    return self._transition(
                        connection, row, private, state='needs_attention',
                        error='bootstrap_authority_changed',
                    )
                if self.backend is None:
                    return self._transition(
                        connection, row, private, state='failed',
                        error='bootstrap_worker_unavailable',
                    )
                private, plan = self._execution_inputs(connection, row)
                self._transition(connection, row, private, state='running')
                identifier = row['id']
            try:
                result = self.backend.execute(
                    identifier, plan, private,
                    deadline=time.monotonic() + 30.0,
                    gate=lambda: self._gate(identifier),
                )
                if (type(result) is not JellyfinBootstrapExecutionResult
                        or result.state != 'wiring_partial'):
                    raise JellyfinBootstrapExecutionError('invalid_bootstrap_execution')
            except JellyfinBootstrapExecutionError as failure:
                error = (failure.code if failure.code != 'invalid_bootstrap_execution'
                         else 'invalid_bootstrap_result')
                state = ('needs_attention' if failure.uncertain_effect
                         or bool(failure.completed_steps)
                         or error in {'bootstrap_authority_changed',
                                      'bootstrap_endpoint_changed'} else 'failed')
                with self.db.transaction() as connection:
                    row = self._find(connection, identifier)
                    return self._transition(
                        connection, row, self._decode(row), state=state, error=error)
            except (OSError, ValueError, TypeError, AttributeError, RuntimeError):
                with self.db.transaction() as connection:
                    row = self._find(connection, identifier)
                    return self._transition(
                        connection, row, self._decode(row), state='failed',
                        error='bootstrap_worker_unavailable')
            with self.db.transaction() as connection:
                row = self._find(connection, identifier)
                try:
                    verified = result.readback
                    stored = PrivateJellyfinReadback(
                        apiKey=verified.api_key,
                        serverId=verified.server_id,
                        serverName=verified.server_name,
                        version=verified.version,
                        libraries=tuple(
                            PrivateMediaLibrary(
                                name=name,
                                collectionType=collection,
                                itemId=item_id,
                                locations=locations,
                            )
                            for name, collection, item_id, locations
                            in verified.libraries
                        ),
                    )
                    private = PrivateMediaServiceBootstrap.model_validate(
                        self._decode(row).model_dump(mode='python')
                        | {'readback': stored.model_dump(mode='python')},
                    )
                except (ValidationError, ValueError, TypeError, AttributeError):
                    return self._transition(
                        connection, row, self._decode(row), state='failed',
                        error='invalid_bootstrap_result')
                return self._transition(
                    connection, row, private,
                    state='wiring_partial')
