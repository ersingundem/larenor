"""Encrypted Core remote profile repository with current-session authorization."""
import hashlib
import hmac
import json
import re
import secrets
import sqlite3
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
    PersonalProfileAuthority,
    PersonalProfileDeletion,
    PersonalProfileDeletionResponse,
    PersonalProfileRef,
    PersonalProfileResponse,
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
    def _digest(value):
        if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{64}', value):
            raise ValueError('invalid_digest')

    @staticmethod
    def _revision(value):
        if type(value) is not int or not 1 <= value <= 2**63 - 1:
            raise ApiError('invalid_request')

    @staticmethod
    def _collection_revision(value):
        if type(value) is not int or not 0 <= value <= 2**63 - 1:
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

    def _audit_tag(self, action, status, actor_id, family_id, request_id,
                   target_id, created_at):
        payload = json.dumps(
            [self.scope.coreId, self.scope.homeId, action, status, actor_id,
             family_id, request_id, target_id, created_at],
            separators=(',', ':'), ensure_ascii=True,
        ).encode('ascii')
        return hmac.new(
            self._key, b'larenor-personal-profile-audit-v2\0' + payload,
            hashlib.sha256,
        ).hexdigest()

    def _audit_rows_digest(self, connection):
        rows = connection.execute(
            'SELECT sequence,action,status,actor_id,family_id,request_id,'
            'target_id,created_at,authentication_tag '
            'FROM personal_profile_audit ORDER BY sequence LIMIT ?',
            (schema.MAX_AUDIT + 1,),
        ).fetchall()
        if len(rows) > schema.MAX_AUDIT:
            raise ValueError('invalid_audit')
        payload = json.dumps(
            [list(row) for row in rows], separators=(',', ':'),
            ensure_ascii=True,
        ).encode('ascii')
        return len(rows), hashlib.sha256(payload).hexdigest()

    def _audit_state_tag(self, revision, count, rows_digest):
        payload = json.dumps(
            [self.scope.coreId, self.scope.homeId, revision, count, rows_digest],
            separators=(',', ':'),
        ).encode('ascii')
        return hmac.new(
            self._key, b'larenor-personal-profile-audit-state-v2\0' + payload,
            hashlib.sha256,
        ).hexdigest()

    def _audit_state(self, connection, *, create=False):
        rows = connection.execute(
            'SELECT * FROM personal_profile_audit_state LIMIT 2'
        ).fetchall()
        count, rows_digest = self._audit_rows_digest(connection)
        if not rows:
            if not create or count:
                raise ValueError('invalid_audit_state')
            tag = self._audit_state_tag(0, 0, rows_digest)
            connection.execute(
                'INSERT INTO personal_profile_audit_state VALUES(1,0,0,?,?)',
                (rows_digest, tag),
            )
            return {'revision': 0, 'record_count': 0,
                    'rows_digest': rows_digest, 'authentication_tag': tag}
        if len(rows) != 1:
            raise ValueError('invalid_audit_state')
        row = rows[0]
        if (row['singleton'] != 1 or type(row['revision']) is not int or
                not 0 <= row['revision'] <= 2**63 - 1 or
                type(row['record_count']) is not int or
                not 0 <= row['record_count'] <= schema.MAX_AUDIT or
                row['record_count'] != count or
                not hmac.compare_digest(row['rows_digest'], rows_digest) or
                not hmac.compare_digest(
                    row['authentication_tag'], self._audit_state_tag(
                        row['revision'], count, rows_digest))):
            raise ValueError('invalid_audit_state')
        return row

    def _seal_audit(self, connection, current):
        if current['revision'] >= 2**63 - 1:
            raise ValueError('invalid_audit_state')
        count, rows_digest = self._audit_rows_digest(connection)
        revision = current['revision'] + 1
        connection.execute(
            'UPDATE personal_profile_audit_state SET '
            'revision=?,record_count=?,rows_digest=?,authentication_tag=? '
            'WHERE singleton=1',
            (revision, count, rows_digest,
             self._audit_state_tag(revision, count, rows_digest)),
        )

    def _request_hash(self, action, target_id, body):
        payload = json.dumps(
            [self.scope.coreId, self.scope.homeId, action, target_id, body],
            sort_keys=True, separators=(',', ':'), ensure_ascii=True,
        ).encode('ascii')
        return hmac.new(
            self._key, b'larenor-personal-profile-request-v2\0' + payload,
            hashlib.sha256,
        ).hexdigest()

    def _profile_id(self, actor, request_id):
        return hmac.new(
            self._key,
            (f'larenor-personal-profile-id-v2:{self.scope.coreId}:'
             f'{self.scope.homeId}:{actor.id}:{actor.family_id}:'
             f'{request_id}').encode('ascii'),
            hashlib.sha256,
        ).hexdigest()[:32]

    @staticmethod
    def _profile_data(body):
        return StoredPersonalProfile.model_validate({
            name: getattr(body, name)
            for name in ('label', 'protocol', 'host', 'port', 'username')
        })

    def _receipt_aad(self, owner_id, family_id, request_id, action,
                     request_hash):
        return (
            f'larenor-personal-profile-receipt-v2:{self.scope.coreId}:'
            f'{self.scope.homeId}:{owner_id}:{family_id}:{request_id}:'
            f'{action}:{request_hash}'
        ).encode('ascii')

    def _receipt(self, connection, actor, request_id, action, request_hash):
        self._id(request_id)
        row = connection.execute(
            'SELECT * FROM personal_profile_receipts '
            'WHERE owner_id=? AND family_id=? AND request_id=?',
            (actor.id, actor.family_id, request_id),
        ).fetchone()
        if row is None:
            return None
        if (row['action'] != action or
                not hmac.compare_digest(row['request_hash'], request_hash)):
            raise ApiError('idempotency_conflict', 409)
        if (type(row['nonce']) is not bytes or len(row['nonce']) != 12 or
                type(row['ciphertext']) is not bytes or
                not 16 <= len(row['ciphertext']) <= 8192):
            raise ValueError('invalid_receipt')
        plain = self._cipher.decrypt(
            row['nonce'], row['ciphertext'], self._receipt_aad(
                actor.id, actor.family_id, request_id, action, request_hash))
        decoded = json.loads(plain)
        if not isinstance(decoded, dict):
            raise ValueError('invalid_receipt')
        return decoded

    def _save_receipt(self, connection, actor, request_id, action,
                      request_hash, result):
        plain = json.dumps(
            result, sort_keys=True, separators=(',', ':'), ensure_ascii=True,
        ).encode('ascii')
        if len(plain) > 8176:
            raise ApiError('invalid_request')
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(
            nonce, plain, self._receipt_aad(
                actor.id, actor.family_id, request_id, action, request_hash))
        connection.execute(
            'INSERT INTO personal_profile_receipts('
            'owner_id,family_id,request_id,action,request_hash,nonce,ciphertext,created_at) '
            'VALUES(?,?,?,?,?,?,?,?)',
            (actor.id, actor.family_id, request_id, action, request_hash,
             nonce, ciphertext, self.settings.clock()),
        )
        connection.execute(
            'DELETE FROM personal_profile_receipts WHERE sequence IN ('
            'SELECT sequence FROM personal_profile_receipts WHERE owner_id=? '
            'ORDER BY sequence DESC LIMIT -1 OFFSET ?)',
            (actor.id, schema.MAX_RECEIPTS_PER_ACCOUNT),
        )
        connection.execute(
            'DELETE FROM personal_profile_receipts WHERE sequence IN ('
            'SELECT sequence FROM personal_profile_receipts '
            'ORDER BY sequence DESC LIMIT -1 OFFSET ?)',
            (schema.MAX_RECEIPTS,),
        )

    def _current_replay(self, connection, actor, response, model):
        decoded = model.model_validate(response).model_dump()
        if decoded['authority'] != self._authority(connection, actor):
            raise ApiError('operation_replay', 409)
        return decoded

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

    def _authority(self, connection, actor, state=None, *, expected_account=None,
                   expected_collection=None):
        row = connection.execute(
            'SELECT revision FROM users WHERE id=?', (actor.id,)
        ).fetchone()
        if row is None or type(row['revision']) is not int or row['revision'] < 1:
            raise ValueError('invalid_account')
        if expected_account is not None and row['revision'] != expected_account:
            raise ApiError('revision_conflict', 409)
        state = self._state(connection, actor.id) if state is None else state
        collection = 0 if state is None else state['revision']
        if (expected_collection is not None and
                collection != expected_collection):
            raise ApiError('revision_conflict', 409)
        return PersonalProfileAuthority(
            **self.scope.model_dump(), accountId=actor.id,
            sessionFamilyId=actor.family_id, accountRevision=row['revision'],
            collectionRevision=collection,
        ).model_dump()

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
    def _transaction(self, actor, core_id, home_id, *, action=None,
                     target_id=None, request_id=None):
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
                audit_state = self._audit_state(
                    connection, create=True) if action else None
                connection.execute('SAVEPOINT personal_profile_action')
                try:
                    yield connection
                except ApiError as error:
                    connection.execute('ROLLBACK TO personal_profile_action')
                    denied = error
                connection.execute('RELEASE personal_profile_action')
                if action:
                    created_at = self.settings.clock()
                    tag = self._audit_tag(
                        action, 'denied' if denied else 'success', actor.id,
                        actor.family_id, request_id, target_id, created_at)
                    connection.execute(
                        'INSERT INTO personal_profile_audit('
                        'action,status,actor_id,family_id,request_id,target_id,'
                        'created_at,authentication_tag) VALUES(?,?,?,?,?,?,?,?)',
                        (action, 'denied' if denied else 'success', actor.id,
                         actor.family_id, request_id, target_id, created_at, tag),
                    )
                    connection.execute(
                        'DELETE FROM personal_profile_audit WHERE sequence IN ('
                        'SELECT sequence FROM personal_profile_audit ORDER BY sequence DESC '
                        'LIMIT -1 OFFSET ?)', (schema.MAX_AUDIT,),
                    )
                    self._seal_audit(connection, audit_state)
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
            **self.scope.model_dump(), kind='coreRemoteProfile', id=row['id'],
            accountId=row['owner_id'])
        return PersonalProfile(
            **data.model_dump(), ref=ref, revision=row['revision']).model_dump()

    def validate_storage(self):
        try:
            with self.db.transaction() as connection:
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
                receipts = connection.execute(
                    'SELECT * FROM personal_profile_receipts LIMIT ?',
                    (schema.MAX_RECEIPTS + 1,),
                ).fetchall()
                if len(receipts) > schema.MAX_RECEIPTS:
                    raise ValueError('invalid_receipts')
                per_owner = {}
                for row in receipts:
                    self._id(row['owner_id'])
                    self._id(row['family_id'])
                    self._id(row['request_id'])
                    self._digest(row['request_hash'])
                    if row['action'] not in ('create', 'update', 'delete'):
                        raise ValueError('invalid_receipt')
                    if (type(row['nonce']) is not bytes or len(row['nonce']) != 12 or
                            type(row['ciphertext']) is not bytes or
                            not 16 <= len(row['ciphertext']) <= 8192):
                        raise ValueError('invalid_receipt')
                    plain = self._cipher.decrypt(
                        row['nonce'], row['ciphertext'], self._receipt_aad(
                            row['owner_id'], row['family_id'], row['request_id'],
                            row['action'], row['request_hash']))
                    if not isinstance(json.loads(plain), dict):
                        raise ValueError('invalid_receipt')
                    per_owner[row['owner_id']] = per_owner.get(row['owner_id'], 0) + 1
                    if per_owner[row['owner_id']] > schema.MAX_RECEIPTS_PER_ACCOUNT:
                        raise ValueError('invalid_receipts')
                audits = connection.execute(
                    'SELECT * FROM personal_profile_audit LIMIT ?',
                    (schema.MAX_AUDIT + 1,),
                ).fetchall()
                for row in audits:
                    self._id(row['actor_id'])
                    self._id(row['family_id'])
                    self._id(row['request_id'])
                    self._id(row['target_id'])
                    if (row['action'] not in ('create', 'update', 'delete') or
                            row['status'] not in ('success', 'denied') or
                            type(row['created_at']) not in (int, float) or
                            not hmac.compare_digest(
                                row['authentication_tag'], self._audit_tag(
                                    row['action'], row['status'], row['actor_id'],
                                    row['family_id'], row['request_id'],
                                    row['target_id'], row['created_at']))):
                        raise ValueError('invalid_audit')
                self._audit_state(connection, create=True)
                if counts or len(audits) > schema.MAX_AUDIT:
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
                'authority': self._authority(connection, actor, state),
                'profiles': [self._public(row, self._decode(row)) for row in rows],
            }

    def get(self, actor, core_id, home_id, profile_id, expected_revision,
            expected_collection_revision, expected_account_revision):
        self._revision(expected_revision)
        self._revision(expected_account_revision)
        self._collection_revision(expected_collection_revision)
        with self._transaction(actor, core_id, home_id) as connection:
            authority = self._authority(
                connection, actor, expected_account=expected_account_revision,
                expected_collection=expected_collection_revision)
            row, data = self._row(connection, actor.id, profile_id)
            if row['revision'] != expected_revision:
                raise ApiError('revision_conflict', 409)
            return {'authority': authority, 'profile': self._public(row, data)}

    def create(self, actor, core_id, home_id, body):
        body = CreatePersonalProfileRequest.model_validate(body)
        profile_id = self._profile_id(actor, body.requestId)
        request_hash = self._request_hash(
            'create', None, body.model_dump(mode='json'))
        with self._transaction(
                actor, core_id, home_id, action='create', target_id=profile_id,
                request_id=body.requestId) as connection:
            self._authority(
                connection, actor,
                expected_account=body.expectedAccountRevision)
            replay = self._receipt(
                connection, actor, body.requestId, 'create', request_hash)
            if replay is not None:
                return self._current_replay(
                    connection, actor, replay, PersonalProfileResponse)
            state = self._state(connection, actor.id, create=True)
            self._authority(
                connection, actor, state,
                expected_account=body.expectedAccountRevision,
                expected_collection=body.expectedCollectionRevision)
            if state['record_count'] >= schema.MAX_PROFILES_PER_ACCOUNT:
                raise ApiError('revision_conflict', 409)
            data = self._profile_data(body)
            self._save(connection, actor.id, profile_id, 1, data)
            self._bump(connection, actor.id, 1)
            row = {'owner_id': actor.id, 'id': profile_id, 'revision': 1}
            result = {
                'authority': self._authority(connection, actor),
                'profile': self._public(row, data),
            }
            self._save_receipt(
                connection, actor, body.requestId, 'create', request_hash,
                result)
        return result

    def update(self, actor, core_id, home_id, profile_id, body):
        body = UpdatePersonalProfileRequest.model_validate(body)
        request_hash = self._request_hash(
            'update', profile_id, body.model_dump(mode='json'))
        with self._transaction(
                actor, core_id, home_id, action='update', target_id=profile_id,
                request_id=body.requestId) as connection:
            self._authority(
                connection, actor,
                expected_account=body.expectedAccountRevision)
            replay = self._receipt(
                connection, actor, body.requestId, 'update', request_hash)
            if replay is not None:
                return self._current_replay(
                    connection, actor, replay, PersonalProfileResponse)
            self._authority(
                connection, actor,
                expected_account=body.expectedAccountRevision,
                expected_collection=body.expectedCollectionRevision)
            row, existing = self._row(connection, actor.id, profile_id)
            if row['revision'] != body.expectedRevision:
                raise ApiError('revision_conflict', 409)
            data = self._profile_data(body)
            if data != existing:
                if row['revision'] >= 2**63 - 1:
                    raise ApiError('revision_conflict', 409)
                row = dict(row)
                row['revision'] += 1
                self._save(connection, actor.id, profile_id, row['revision'], data)
                self._bump(connection, actor.id)
            result = {
                'authority': self._authority(connection, actor),
                'profile': self._public(row, data),
            }
            self._save_receipt(
                connection, actor, body.requestId, 'update', request_hash,
                result)
        return result

    def delete(self, actor, core_id, home_id, profile_id, expected_revision,
               expected_collection_revision, expected_account_revision,
               request_id):
        self._revision(expected_revision)
        self._revision(expected_account_revision)
        self._collection_revision(expected_collection_revision)
        self._id(request_id)
        request_hash = self._request_hash('delete', profile_id, {
            'requestId': request_id,
            'expectedRevision': expected_revision,
            'expectedCollectionRevision': expected_collection_revision,
            'expectedAccountRevision': expected_account_revision,
        })
        with self._transaction(
                actor, core_id, home_id, action='delete', target_id=profile_id,
                request_id=request_id) as connection:
            self._authority(
                connection, actor, expected_account=expected_account_revision)
            replay = self._receipt(
                connection, actor, request_id, 'delete', request_hash)
            if replay is not None:
                return self._current_replay(
                    connection, actor, replay,
                    PersonalProfileDeletionResponse)
            self._authority(
                connection, actor, expected_account=expected_account_revision,
                expected_collection=expected_collection_revision)
            row, _ = self._row(connection, actor.id, profile_id)
            if row['revision'] != expected_revision:
                raise ApiError('revision_conflict', 409)
            connection.execute(
                'DELETE FROM personal_profile_records WHERE owner_id=? AND id=?',
                (actor.id, profile_id),
            )
            self._bump(connection, actor.id, -1)
            ref = PersonalProfileRef(
                **self.scope.model_dump(), kind='coreRemoteProfile',
                id=profile_id, accountId=actor.id)
            result = {
                'authority': self._authority(connection, actor),
                'deletion': PersonalProfileDeletion(
                    ref=ref, deletedRevision=expected_revision).model_dump(),
            }
            self._save_receipt(
                connection, actor, request_id, 'delete', request_hash, result)
        return result
