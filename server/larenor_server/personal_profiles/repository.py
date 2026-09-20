"""Encrypted account-owned profile repository with current-session authorization."""
import hashlib
import hmac
import json
import re
import secrets
import sqlite3
import uuid
from contextlib import contextmanager

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..context import _authentication_tag
from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from . import schema
from .models import (
    CreatePersonalProfileRequest,
    PersonalProfile,
    PersonalProfileRef,
    StoredPersonalProfile,
    UpdatePersonalProfileRequest,
)


class PersonalProfileRepository:
    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings = db, auth, settings
        self.scope = HomeScope.model_validate(context.model_dump())
        self._key, self._cipher = key, AESGCM(key)
        self._context_tag = _authentication_tag(
            key, self.scope.coreId, self.scope.homeId)

    @staticmethod
    def _id(value):
        if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{32}', value):
            raise ApiError('invalid_request')

    @staticmethod
    def _revision(value):
        if type(value) is not int or not 1 <= value <= 2**63 - 1:
            raise ApiError('invalid_request')

    def _check_context(self, connection, core_id, home_id):
        self._id(core_id)
        self._id(home_id)
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError('not_found', 404)
        rows = connection.execute('SELECT * FROM core_context LIMIT 2').fetchall()
        if (len(rows) != 1 or rows[0]['singleton'] != 1 or
                (rows[0]['core_id'], rows[0]['home_id']) != (core_id, home_id) or
                not hmac.compare_digest(rows[0]['authentication_tag'], self._context_tag)):
            raise ApiError('server_unavailable', 503)

    def _state_tag(self, owner_id, revision, count):
        payload = json.dumps(
            [self.scope.coreId, self.scope.homeId, owner_id, revision, count],
            separators=(',', ':'),
        ).encode('ascii')
        return hmac.new(
            self._key, b'larenor-personal-profile-state-v1\0' + payload,
            hashlib.sha256,
        ).hexdigest()

    def _state(self, connection, owner_id, *, create=False):
        rows = connection.execute(
            'SELECT * FROM personal_profile_state WHERE owner_id=? LIMIT 2',
            (owner_id,),
        ).fetchall()
        if not rows:
            if not create:
                return None
            tag = self._state_tag(owner_id, 0, 0)
            connection.execute(
                'INSERT INTO personal_profile_state VALUES(?,?,?,?)',
                (owner_id, 0, 0, tag),
            )
            return {'owner_id': owner_id, 'revision': 0,
                    'record_count': 0, 'authentication_tag': tag}
        if len(rows) != 1:
            raise ValueError('invalid_state')
        row = rows[0]
        if (type(row['revision']) is not int or
                not 0 <= row['revision'] <= 2**63 - 1 or
                type(row['record_count']) is not int or
                not 0 <= row['record_count'] <= schema.MAX_PROFILES_PER_ACCOUNT or
                not hmac.compare_digest(
                    row['authentication_tag'],
                    self._state_tag(owner_id, row['revision'], row['record_count']))):
            raise ValueError('invalid_state')
        return row

    def _bump(self, connection, owner_id, count_delta=0):
        current = self._state(connection, owner_id, create=True)
        if current['revision'] >= 2**63 - 1:
            raise ApiError('revision_conflict', 409)
        revision = current['revision'] + 1
        count = current['record_count'] + count_delta
        if not 0 <= count <= schema.MAX_PROFILES_PER_ACCOUNT:
            raise ApiError('revision_conflict', 409)
        connection.execute(
            'UPDATE personal_profile_state SET revision=?,record_count=?,authentication_tag=? '
            'WHERE owner_id=?',
            (revision, count, self._state_tag(owner_id, revision, count), owner_id),
        )
        return revision

    def _aad(self, owner_id, profile_id, revision):
        return (
            f'larenor-personal-profile-v1:{self.scope.coreId}:{self.scope.homeId}:'
            f'{owner_id}:{profile_id}:{revision}'
        ).encode('ascii')

    def _decode(self, row):
        self._id(row['owner_id'])
        self._id(row['id'])
        self._revision(row['revision'])
        if (type(row['nonce']) is not bytes or len(row['nonce']) != 12 or
                type(row['ciphertext']) is not bytes or
                not 16 <= len(row['ciphertext']) <= 4096):
            raise ValueError('invalid_storage')
        return StoredPersonalProfile.model_validate_json(
            self._cipher.decrypt(
                row['nonce'], row['ciphertext'],
                self._aad(row['owner_id'], row['id'], row['revision']),
            )
        )

    def _save(self, connection, owner_id, profile_id, revision, data):
        data = StoredPersonalProfile.model_validate(data.model_dump())
        plain = data.model_dump_json().encode('utf-8')
        if len(plain) > 4080:
            raise ApiError('invalid_request')
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(
            nonce, plain, self._aad(owner_id, profile_id, revision))
        connection.execute(
            'INSERT INTO personal_profile_records VALUES(?,?,?,?,?) '
            'ON CONFLICT(owner_id,id) DO UPDATE SET '
            'revision=excluded.revision,nonce=excluded.nonce,ciphertext=excluded.ciphertext',
            (owner_id, profile_id, revision, nonce, ciphertext),
        )

    @contextmanager
    def _transaction(self, actor, core_id, home_id, *, action=None, target_id=None):
        self.auth.rate_limit([
            ('personal_profile_write' if action else 'personal_profile_read',
             actor.id, 120)
        ])
        denied = None
        try:
            with self.db.transaction() as connection:
                self.auth.assert_current(connection, actor)
                if actor.must_change_password:
                    raise ApiError('password_change_required', 403)
                self._check_context(connection, core_id, home_id)
                connection.execute('SAVEPOINT personal_profile_action')
                try:
                    yield connection
                except ApiError as error:
                    connection.execute('ROLLBACK TO personal_profile_action')
                    denied = error
                connection.execute('RELEASE personal_profile_action')
                if action:
                    connection.execute(
                        'INSERT INTO personal_profile_audit('
                        'action,status,actor_id,target_id,created_at) VALUES(?,?,?,?,?)',
                        (action, 'denied' if denied else 'success', actor.id,
                         target_id, self.settings.clock()),
                    )
                    connection.execute(
                        'DELETE FROM personal_profile_audit WHERE sequence IN ('
                        'SELECT sequence FROM personal_profile_audit ORDER BY sequence DESC '
                        'LIMIT -1 OFFSET ?)', (schema.MAX_AUDIT,),
                    )
            if denied:
                raise denied
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError('server_unavailable', 503) from None

    def _row(self, connection, owner_id, profile_id):
        self._id(profile_id)
        row = connection.execute(
            'SELECT * FROM personal_profile_records WHERE owner_id=? AND id=?',
            (owner_id, profile_id),
        ).fetchone()
        if row is None:
            raise ApiError('not_found', 404)
        return row, self._decode(row)

    def _public(self, row, data):
        ref = PersonalProfileRef(
            **self.scope.model_dump(), kind='remoteProfile', id=row['id'])
        return PersonalProfile(
            **data.model_dump(), ref=ref, revision=row['revision']).model_dump()

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                states = {
                    row['owner_id']: row
                    for row in connection.execute('SELECT * FROM personal_profile_state')
                }
                counts = {}
                records = connection.execute(
                    'SELECT * FROM personal_profile_records LIMIT 10001').fetchall()
                if len(records) > 10000:
                    raise ValueError('invalid_storage')
                for row in records:
                    self._decode(row)
                    counts[row['owner_id']] = counts.get(row['owner_id'], 0) + 1
                for owner_id, row in states.items():
                    state = self._state(connection, owner_id)
                    if state['record_count'] != counts.pop(owner_id, 0):
                        raise ValueError('invalid_state')
                if counts or connection.execute(
                        'SELECT COUNT(*) FROM personal_profile_audit').fetchone()[0] > schema.MAX_AUDIT:
                    raise ValueError('invalid_storage')
        except (ApiError, InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise StartupError('personal_profile_storage_invalid') from None

    def list(self, actor, core_id, home_id):
        with self._transaction(actor, core_id, home_id) as connection:
            state = self._state(connection, actor.id)
            rows = connection.execute(
                'SELECT * FROM personal_profile_records WHERE owner_id=? '
                'ORDER BY id LIMIT ?',
                (actor.id, schema.MAX_PROFILES_PER_ACCOUNT + 1),
            ).fetchall()
            if len(rows) > schema.MAX_PROFILES_PER_ACCOUNT:
                raise ValueError('invalid_storage')
            if (state is None and rows) or (
                    state is not None and state['record_count'] != len(rows)):
                raise ValueError('invalid_state')
            return {
                'scope': self.scope.model_dump(),
                'collectionRevision': 0 if state is None else state['revision'],
                'profiles': [self._public(row, self._decode(row)) for row in rows],
            }

    def get(self, actor, core_id, home_id, profile_id):
        with self._transaction(actor, core_id, home_id) as connection:
            row, data = self._row(connection, actor.id, profile_id)
            return {'profile': self._public(row, data)}

    def create(self, actor, core_id, home_id, body):
        body = CreatePersonalProfileRequest.model_validate(body)
        profile_id = uuid.uuid4().hex
        with self._transaction(
                actor, core_id, home_id, action='create', target_id=profile_id) as connection:
            state = self._state(connection, actor.id, create=True)
            if state['record_count'] >= schema.MAX_PROFILES_PER_ACCOUNT:
                raise ApiError('revision_conflict', 409)
            self._save(connection, actor.id, profile_id, 1, body)
            self._bump(connection, actor.id, 1)
            row = {'owner_id': actor.id, 'id': profile_id, 'revision': 1}
            result = self._public(row, body)
        return {'profile': result}

    def update(self, actor, core_id, home_id, profile_id, body):
        body = UpdatePersonalProfileRequest.model_validate(body)
        with self._transaction(
                actor, core_id, home_id, action='update', target_id=profile_id) as connection:
            row, existing = self._row(connection, actor.id, profile_id)
            if row['revision'] != body.expectedRevision:
                raise ApiError('revision_conflict', 409)
            data = StoredPersonalProfile.model_validate(body.model_dump(
                exclude={'expectedRevision'}))
            if data != existing:
                if row['revision'] >= 2**63 - 1:
                    raise ApiError('revision_conflict', 409)
                row = dict(row)
                row['revision'] += 1
                self._save(connection, actor.id, profile_id, row['revision'], data)
                self._bump(connection, actor.id)
            result = self._public(row, data)
        return {'profile': result}

    def delete(self, actor, core_id, home_id, profile_id, expected_revision):
        self._revision(expected_revision)
        with self._transaction(
                actor, core_id, home_id, action='delete', target_id=profile_id) as connection:
            row, _ = self._row(connection, actor.id, profile_id)
            if row['revision'] != expected_revision:
                raise ApiError('revision_conflict', 409)
            connection.execute(
                'DELETE FROM personal_profile_records WHERE owner_id=? AND id=?',
                (actor.id, profile_id),
            )
            self._bump(connection, actor.id, -1)
