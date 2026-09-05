"""Encrypted metadata registry. No providers, credentials, filesystem or device operations."""
from contextlib import contextmanager
import hmac
import re
import secrets
import sqlite3
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..context import _authentication_tag
from ..errors import ApiError, StartupError
from .api_models import CreateRecordRequest, SetGrantRequest, StoredRecord, UpdateRecordRequest
from .authorization import evaluate_access
from .models import ActorFacts, GrantSnapshot, HomeScope, Permissions, RegistryRecord, ResourceRef, TargetFacts
from . import schema


FULL = Permissions(read=True, write=True)
NONE = Permissions(read=False, write=False)


class HomeResourceRegistry:
    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings = db, auth, settings
        self.scope = HomeScope.model_validate(context.model_dump())
        self._key, self._cipher = key, AESGCM(key)
        self._context_tag = _authentication_tag(key, self.scope.coreId, self.scope.homeId)

    @staticmethod
    def _id(value):
        if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{32}', value):
            raise ApiError('invalid_request')

    @staticmethod
    def _revision(value):
        if type(value) is not int or not 1 <= value <= 2**63 - 1:
            raise ApiError('invalid_request')

    @staticmethod
    def _next(value):
        if value >= 2**63 - 1:
            raise ApiError('revision_conflict', 409)
        return value + 1

    def _check_context(self, c, core_id, home_id):
        self._id(core_id); self._id(home_id)
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError('not_found', 404)
        rows = c.execute('SELECT * FROM core_context LIMIT 2').fetchall()
        marker = c.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()
        if (len(rows) != 1 or marker is None or marker['value'] != '3' or
                rows[0]['singleton'] != 1 or rows[0]['schema_version'] != 1 or
                (rows[0]['core_id'], rows[0]['home_id']) != (core_id, home_id) or
                not hmac.compare_digest(rows[0]['authentication_tag'], self._context_tag)):
            raise ApiError('server_unavailable', 503)

    def _state(self, c):
        rows = c.execute('SELECT * FROM home_resource_state LIMIT 2').fetchall()
        if len(rows) != 1 or rows[0]['singleton'] != 1:
            raise ValueError('invalid_state')
        r = rows[0]; self._revision(r['revision'])
        for field, limit in [('record_count', schema.MAX_RECORDS), ('grant_count', schema.MAX_TOTAL_GRANTS)]:
            if type(r[field]) is not int or not 0 <= r[field] <= limit:
                raise ValueError('invalid_state')
        tag = schema.state_tag(self._key, self.scope, r['revision'], r['record_count'], r['grant_count'])
        if not hmac.compare_digest(r['authentication_tag'], tag):
            raise ValueError('invalid_state')
        return r

    def _bump(self, c, *, records=0, grants=0):
        old = self._state(c); revision = self._next(old['revision'])
        nr, ng = old['record_count'] + records, old['grant_count'] + grants
        if not 0 <= nr <= schema.MAX_RECORDS or not 0 <= ng <= schema.MAX_TOTAL_GRANTS:
            raise ApiError('revision_conflict', 409)
        c.execute('UPDATE home_resource_state SET revision=?,record_count=?,grant_count=?,authentication_tag=? WHERE singleton=1',
                  (revision, nr, ng, schema.state_tag(self._key, self.scope, revision, nr, ng)))

    def _aad(self, row):
        return (f'larenor-home-resource-v1:{self.scope.coreId}:{self.scope.homeId}:'
                f'{row["id"]}:{row["kind"]}:{row["revision"]}:{row["acl_revision"]}').encode('ascii')

    def _decode(self, row):
        self._id(row['id']); self._revision(row['revision']); self._revision(row['acl_revision'])
        ref = ResourceRef(**self.scope.model_dump(), id=row['id'], kind=row['kind'])
        if (type(row['nonce']) is not bytes or len(row['nonce']) != 12 or
                type(row['ciphertext']) is not bytes or not 16 <= len(row['ciphertext']) <= 32768):
            raise ValueError('invalid_storage')
        data = StoredRecord.model_validate_json(self._cipher.decrypt(row['nonce'], row['ciphertext'], self._aad(row)))
        if len(data.grants) > schema.MAX_GRANTS or any(not p.read for p in data.grants.values()):
            raise ValueError('invalid_grants')
        return ref, data

    def _save(self, c, row, data):
        data = StoredRecord.model_validate(data)
        plain = data.model_dump_json().encode('utf-8')
        if len(plain) > 32752:
            raise ApiError('invalid_request')
        nonce = secrets.token_bytes(12)
        c.execute('INSERT INTO home_resource_records VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET '
                  'revision=excluded.revision,acl_revision=excluded.acl_revision,nonce=excluded.nonce,ciphertext=excluded.ciphertext',
                  (row['id'], row['kind'], row['revision'], row['acl_revision'], nonce,
                   self._cipher.encrypt(nonce, plain, self._aad(row))))

    @contextmanager
    def _transaction(self, actor, core_id, home_id, *, admin=False, action=None, target_id=None):
        self.auth.rate_limit([('home_resource_write' if action else 'home_resource_read', actor.id, 120)])
        error = None
        try:
            with self.db.transaction() as c:
                self.auth.assert_current(c, actor)
                if actor.must_change_password:
                    raise ApiError('password_change_required', 403)
                self._check_context(c, core_id, home_id)
                row = c.execute('SELECT * FROM users WHERE id=?', (actor.id,)).fetchone()
                facts = ActorFacts(userId=row['id'], revision=row['revision'], role=row['role'],
                                   disabled=bool(row['disabled']), mustChangePassword=bool(row['must_change_password']),
                                   sessionCurrent=True)
                if admin and facts.role != 'admin':
                    raise ApiError('forbidden', 403)
                self._state(c)
                c.execute('SAVEPOINT registry_action')
                try:
                    yield c, facts
                except ApiError as caught:
                    c.execute('ROLLBACK TO registry_action'); error = caught
                c.execute('RELEASE registry_action')
                if action:
                    c.execute('INSERT INTO home_resource_audit(action,status,actor_id,target_id,created_at) VALUES(?,?,?,?,?)',
                              (action, 'denied' if error else 'success', actor.id, target_id, self.settings.clock()))
                    c.execute('DELETE FROM home_resource_audit WHERE sequence IN (SELECT sequence FROM home_resource_audit '
                              'ORDER BY sequence DESC LIMIT -1 OFFSET ?)', (schema.MAX_AUDIT,))
            if error:
                raise error
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError('server_unavailable', 503) from None

    def _target(self, c, record_id):
        self._id(record_id)
        row = c.execute('SELECT * FROM home_resource_records WHERE id=?', (record_id,)).fetchone()
        if row is None:
            raise ApiError('not_found', 404)
        ref, data = self._decode(row)
        return row, ref, data

    def _decision(self, actor, row, ref, data, action, **expected):
        permission = data.grants.get(actor.userId)
        grant = None if permission is None else GrantSnapshot(subjectId=actor.userId, target=ref,
            aclRevision=row['acl_revision'], permissions=permission)
        return evaluate_access(self.scope, actor, TargetFacts(ref=ref, revision=row['revision'],
            aclRevision=row['acl_revision'], active=True), grant, action, **expected)

    def _require(self, actor, row, ref, data, action='read', **expected):
        # First hide inaccessible records; revision errors must not confirm their existence.
        if not self._decision(actor, row, ref, data, 'read').allowed:
            raise ApiError('not_found', 404)
        decision = self._decision(actor, row, ref, data, action, **expected)
        if not decision.allowed:
            raise ApiError('revision_conflict' if decision.code == 'revision_conflict' else 'forbidden',
                           409 if decision.code == 'revision_conflict' else 403)

    def _public(self, actor, row, ref, data):
        permissions = FULL if actor.role == 'admin' else data.grants.get(actor.userId, NONE)
        return RegistryRecord(ref=ref, revision=row['revision'], aclRevision=row['acl_revision'],
                              label=data.label, order=data.order, permissions=permissions).model_dump()

    def validate_storage(self):
        try:
            with self.db.connection() as c:
                c.execute('BEGIN')
                self._check_context(c, self.scope.coreId, self.scope.homeId)
                state = self._state(c); records = grants = 0
                for row in c.execute('SELECT * FROM home_resource_records LIMIT ?', (schema.MAX_RECORDS + 1,)):
                    records += 1
                    if records > schema.MAX_RECORDS:
                        raise ValueError()
                    _, data = self._decode(row); grants += len(data.grants)
                if (records, grants) != (state['record_count'], state['grant_count']):
                    raise ValueError()
                if c.execute('SELECT COUNT(*) FROM home_resource_audit').fetchone()[0] > schema.MAX_AUDIT:
                    raise ValueError()
        except (ApiError, InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise StartupError('home_resource_storage_invalid') from None

    def list(self, actor, core_id, home_id, *, after=None, expected_registry_revision=None, limit=25):
        if type(limit) is not int or not 1 <= limit <= 100 or (after is not None and expected_registry_revision is None):
            raise ApiError('invalid_request')
        if after is not None:
            self._id(after)
        if expected_registry_revision is not None:
            self._revision(expected_registry_revision)
        with self._transaction(actor, core_id, home_id) as (c, facts):
            state = self._state(c)
            if expected_registry_revision is not None and expected_registry_revision != state['revision']:
                raise ApiError('revision_conflict', 409)
            if after is not None:
                self._require(facts, *self._target(c, after))
            entries = []
            for row in c.execute('SELECT * FROM home_resource_records WHERE id > ? ORDER BY id LIMIT ?',
                                 (after or '', schema.MAX_RECORDS + 1)):
                ref, data = self._decode(row)
                if self._decision(facts, row, ref, data, 'read').allowed:
                    entries.append(self._public(facts, row, ref, data))
                    if len(entries) > limit:
                        break
            return {'scope': self.scope.model_dump(), 'entries': entries[:limit],
                    'registryRevision': state['revision'], 'nextAfter': entries[limit - 1]['ref']['id'] if len(entries) > limit else None}

    def get(self, actor, core_id, home_id, record_id):
        with self._transaction(actor, core_id, home_id) as (c, facts):
            row, ref, data = self._target(c, record_id); self._require(facts, row, ref, data)
            return {'record': self._public(facts, row, ref, data)}

    def authorize(self, actor, core_id, home_id, record_id, action, *, expected_revision,
                  expected_acl_revision, expected_user_revision, cancelled=False):
        """Current in-process check only; no command endpoint or reusable execution permit."""
        with self._transaction(actor, core_id, home_id) as (c, facts):
            row, ref, data = self._target(c, record_id)
            self._require(facts, row, ref, data, action, expected_revision=expected_revision,
                          expected_acl_revision=expected_acl_revision, expected_user_revision=expected_user_revision,
                          cancelled=cancelled)

    def create(self, actor, core_id, home_id, body):
        body = CreateRecordRequest.model_validate(body); identity = uuid.uuid4().hex
        with self._transaction(actor, core_id, home_id, admin=True, action='create', target_id=identity) as (c, facts):
            if self._state(c)['record_count'] >= schema.MAX_RECORDS:
                raise ApiError('revision_conflict', 409)
            row = {'id': identity, 'kind': body.kind, 'revision': 1, 'acl_revision': 1}
            data = StoredRecord(label=body.label, order=body.order, grants={})
            self._save(c, row, data); self._bump(c, records=1)
            ref = ResourceRef(**self.scope.model_dump(), id=identity, kind=body.kind)
            result = self._public(facts, row, ref, data)
        return {'record': result}

    def update(self, actor, core_id, home_id, record_id, body):
        body = UpdateRecordRequest.model_validate(body)
        with self._transaction(actor, core_id, home_id, admin=True, action='update', target_id=record_id) as (c, facts):
            row, ref, data = self._target(c, record_id)
            self._require(facts, row, ref, data, 'write', expected_revision=body.expectedRevision,
                          expected_acl_revision=body.expectedAclRevision)
            if (body.label, body.order) != (data.label, data.order):
                row = dict(row); row['revision'] = self._next(row['revision'])
                data = StoredRecord(label=body.label, order=body.order, grants=data.grants)
                self._save(c, row, data); self._bump(c)
            result = self._public(facts, row, ref, data)
        return {'record': result}

    def delete(self, actor, core_id, home_id, record_id, expected_revision, expected_acl_revision):
        self._revision(expected_revision); self._revision(expected_acl_revision)
        with self._transaction(actor, core_id, home_id, admin=True, action='delete', target_id=record_id) as (c, facts):
            row, ref, data = self._target(c, record_id)
            self._require(facts, row, ref, data, 'write', expected_revision=expected_revision,
                          expected_acl_revision=expected_acl_revision)
            c.execute('DELETE FROM home_resource_records WHERE id=?', (record_id,))
            self._bump(c, records=-1, grants=-len(data.grants))

    def grants(self, actor, core_id, home_id, record_id):
        with self._transaction(actor, core_id, home_id, admin=True) as (c, _):
            row, ref, data = self._target(c, record_id)
            return {'aclRevision': row['acl_revision'], 'grants': [GrantSnapshot(subjectId=subject, target=ref,
                    aclRevision=row['acl_revision'], permissions=p).model_dump() for subject, p in sorted(data.grants.items())]}

    def set_grant(self, actor, core_id, home_id, record_id, subject_id, body):
        body = SetGrantRequest.model_validate(body); self._id(subject_id)
        with self._transaction(actor, core_id, home_id, admin=True, action='grant', target_id=record_id) as (c, facts):
            row, ref, data = self._target(c, record_id)
            self._require(facts, row, ref, data, 'write', expected_acl_revision=body.expectedAclRevision)
            if c.execute('SELECT id FROM users WHERE id=?', (subject_id,)).fetchone() is None:
                raise ApiError('not_found', 404)
            existing = data.grants.get(subject_id, NONE)
            if existing != body.permissions:
                grants = dict(data.grants)
                if body.permissions.read:
                    grants[subject_id] = body.permissions
                else:
                    grants.pop(subject_id, None)
                if len(grants) > schema.MAX_GRANTS:
                    raise ApiError('revision_conflict', 409)
                delta = len(grants) - len(data.grants)
                row = dict(row); row['acl_revision'] = self._next(row['acl_revision'])
                data = StoredRecord(label=data.label, order=data.order, grants=grants)
                self._save(c, row, data); self._bump(c, grants=delta)
            result = GrantSnapshot(subjectId=subject_id, target=ref, aclRevision=row['acl_revision'],
                                   permissions=body.permissions).model_dump()
        return {'grant': result}
