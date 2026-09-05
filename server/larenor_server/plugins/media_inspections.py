"""Durable aggregate observations. Backend work never holds a DB transaction.

The worker can repeat read-only inspection after a crash. It receives only the
current, rederived disabled stack plan, and has no installation action here.
"""

from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
import re
import secrets
import sqlite3
import stat
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..admin.service import utc
from ..errors import ApiError, StartupError
from .catalog import load_catalog
from .media_inspection_models import (CancelMediaInspectionRequest, CreateMediaInspectionRequest,
                                      MediaInspection, MediaInspectionPayload)
from .preflight_models import PreflightResult
from .stack_plan import verify_media_stack_plan


MAX_INSPECTIONS = 256
MAX_ACTIVE = 16
MAX_CIPHERTEXT = 131072
BINDING = ('id', 'sequence', 'revision', 'actor_id', 'actor_revision', 'family_id', 'request_id',
           'preparation_id', 'state', 'phase', 'cancel_requested', 'error_code', 'created_at', 'updated_at')


def _identifier(value):
    if type(value) is not str or not re.fullmatch(r'[0-9a-f]{32}', value):
        raise ApiError('invalid_request')


def _body(value, model):
    try:
        return model.model_validate(value.model_dump(mode='python'))
    except (ValueError, TypeError, AttributeError):
        raise ApiError('invalid_request') from None


class MediaInspectionManagement:
    def __init__(self, db, auth, settings, key, preparations, backend=None):
        self.db, self.auth, self.settings = db, auth, settings
        self.preparations, self.backend = preparations, backend
        self._cipher = AESGCM(key)

    def _assert_admin(self, connection, actor):
        return self.preparations.plugins._assert_admin(connection, actor)

    @staticmethod
    def _aad(row):
        return b'larenor:media:inspections:schema=1:' + json.dumps(
            {key: row[key] for key in BINDING}, sort_keys=True, separators=(',', ':')).encode('ascii')

    @staticmethod
    def _public(row, payload):
        plan = payload.plan
        return {'id': row['id'], 'requestId': row['request_id'], 'preparationId': row['preparation_id'],
                'preparationRevision': payload.request.expectedRevision, 'coreId': plan.coreId, 'homeId': plan.homeId,
                'catalogDigest': plan.catalogDigest, 'planHash': plan.planHash, 'platform': plan.platform,
                'revision': row['revision'], 'state': row['state'], 'phase': row['phase'],
                'cancelRequested': bool(row['cancel_requested']), 'createdAt': utc(row['created_at']),
                'updatedAt': utc(row['updated_at']), 'result': payload.result, 'errorCode': row['error_code']}

    def _same_context(self, payload):
        return (payload.plan.coreId == self.preparations.context.coreId
                and payload.plan.homeId == self.preparations.context.homeId)

    def _read(self, row):
        payload = self._decode(row)
        if not self._same_context(payload):
            raise ApiError('media_context_changed', 409)
        return payload

    def _decode(self, row):
        try:
            for key in ('id', 'actor_id', 'family_id', 'request_id', 'preparation_id'):
                if type(row[key]) is not str or not re.fullmatch(r'[0-9a-f]{32}', row[key]):
                    raise ValueError()
            for key in ('sequence', 'revision', 'actor_revision'):
                if type(row[key]) is not int or not 1 <= row[key] <= 2**63 - 2:
                    raise ValueError()
            if (row['cancel_requested'] not in (0, 1) or len(row['nonce']) != 12 or
                    not 16 <= len(row['ciphertext']) <= MAX_CIPHERTEXT or
                    any(type(row[key]) is not int or not 0 <= row[key] <= 253402300799
                        for key in ('created_at', 'updated_at'))):
                raise ValueError()
            payload = MediaInspectionPayload.model_validate_json(
                self._cipher.decrypt(row['nonce'], row['ciphertext'], self._aad(row)))
            request, plan = payload.request, payload.plan
            if (request.requestId != row['request_id'] or request.preparationId != row['preparation_id'] or
                    request.preparationId != plan.preparationId or request.planHash != plan.planHash or
                    request.expectedRevision != 1):
                raise ValueError()
            # Keep authenticated historical observations readable after catalog
            # updates. Current dispatch independently rederives every child plan.
            canonical = json.dumps(plan.model_dump(mode='json', exclude={'planHash'}), sort_keys=True,
                                   separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode('utf-8')
            if hashlib.sha256(canonical).hexdigest() != plan.planHash:
                raise ValueError()
            MediaInspection.model_validate(self._public(row, payload))
            return payload
        except (InvalidTag, ValueError, TypeError, OverflowError, IndexError, RecursionError):
            raise ApiError('media_inspection_storage_unavailable', 503) from None

    def _save(self, connection, row, payload):
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(nonce, payload.model_dump_json().encode('utf-8'), self._aad(row))
        self._decode(dict(row) | {'nonce': nonce, 'ciphertext': ciphertext})
        connection.execute('UPDATE media_inspections SET ' + ','.join(key + '=?' for key in BINDING) +
                           ',nonce=?,ciphertext=? WHERE id=?', (*[row[key] for key in BINDING], nonce, ciphertext, row['id']))

    def _transition(self, connection, row, payload, *, state, result=None, error=None, cancel=False):
        changed = dict(row)
        changed.update(revision=row['revision'] + 1, state=state,
                       phase='checking_requirements' if state == 'running' else 'complete',
                       cancel_requested=int(cancel), error_code=error,
                       updated_at=max(row['updated_at'], int(self.settings.clock())))
        value = payload.model_copy(update={'result': result})
        self._save(connection, changed, value)
        return {'inspection': self._public(changed, value)}

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                connection.execute('BEGIN')
                active, running = set(), 0
                for count, row in enumerate(connection.execute('SELECT * FROM media_inspections LIMIT ?', (MAX_INSPECTIONS + 1,))):
                    if count >= MAX_INSPECTIONS:
                        raise ValueError()
                    payload = self._decode(row)
                    if not self._same_context(payload):
                        raise ValueError()
                    if row['state'] in ('queued', 'running'):
                        if row['preparation_id'] in active or len(active) >= MAX_ACTIVE:
                            raise ValueError()
                        active.add(row['preparation_id'])
                    running += row['state'] == 'running'
                    if running > 1:
                        raise ValueError()
        except (ApiError, ValueError, sqlite3.Error, IndexError):
            raise StartupError('invalid_media_inspections_storage') from None

    def capabilities(self, actor):
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_admin(connection, actor)
            return {'inspectionConfigured': self.backend is not None, 'installAvailable': False}

    def create(self, actor, body):
        with self.db.transaction() as connection:
            actor_revision = self._assert_admin(connection, actor)
            body = _body(body, CreateMediaInspectionRequest)
            previous = connection.execute('SELECT * FROM media_inspections WHERE actor_id=? AND request_id=?',
                                          (actor.id, body.requestId)).fetchone()
            if previous:
                payload = self._read(previous)
                if payload.request != body:
                    raise ApiError('media_inspection_conflict', 409)
                return {'inspection': self._public(previous, payload)}
            if self.backend is None:
                raise ApiError('plugin_worker_unavailable', 503)
            preparation = connection.execute('SELECT * FROM media_preparations WHERE id=?', (body.preparationId,)).fetchone()
            if preparation is None:
                raise ApiError('not_found', 404)
            prepared = self.preparations._decode(preparation)
            if preparation['state'] != 'prepared':
                raise ApiError('media_preparation_changed', 409)
            if preparation['revision'] != body.expectedRevision:
                raise ApiError('revision_conflict', 409)
            if prepared.plan.planHash != body.planHash:
                raise ApiError('media_preparation_changed', 409)
            if not self._same_context(prepared):
                raise ApiError('media_context_changed', 409)
            try:
                catalog = load_catalog()
                if catalog.digest != self.preparations.plugins._catalog.digest:
                    raise ValueError()
                plan = verify_media_stack_plan(prepared.plan, catalog)
            except (ValueError, TypeError, OSError):
                raise ApiError('media_catalog_changed', 409) from None
            if connection.execute("SELECT 1 FROM media_inspections WHERE preparation_id=? AND state IN ('queued','running')",
                                  (body.preparationId,)).fetchone():
                raise ApiError('media_inspection_conflict', 409)
            if (connection.execute('SELECT COUNT(*) FROM media_inspections').fetchone()[0] >= MAX_INSPECTIONS or
                    connection.execute("SELECT COUNT(*) FROM media_inspections WHERE state IN ('queued','running')").fetchone()[0] >= MAX_ACTIVE):
                raise ApiError('media_inspection_limit_reached', 409)
            if self._assert_admin(connection, actor) != actor_revision:
                raise ApiError('forbidden', 403)
            now = int(self.settings.clock())
            sequence = connection.execute('SELECT COALESCE(MAX(sequence),0)+1 FROM media_inspections').fetchone()[0]
            row = {'id': uuid.uuid4().hex, 'sequence': sequence, 'revision': 1, 'actor_id': actor.id,
                   'actor_revision': actor_revision, 'family_id': actor.family_id, 'request_id': body.requestId,
                   'preparation_id': body.preparationId, 'state': 'queued', 'phase': 'queued', 'cancel_requested': 0,
                   'error_code': None, 'created_at': now, 'updated_at': now}
            payload = MediaInspectionPayload(request=body, plan=plan)
            connection.execute('INSERT INTO media_inspections(' + ','.join(BINDING) + ',nonce,ciphertext) VALUES(' +
                               ','.join('?' for _ in range(len(BINDING) + 2)) + ')', (*[row[key] for key in BINDING], b'', b''))
            self._save(connection, row, payload)
            return {'inspection': self._public(row, payload)}

    @staticmethod
    def _find(connection, identifier):
        row = connection.execute('SELECT * FROM media_inspections WHERE id=?', (identifier,)).fetchone()
        if row is None:
            raise ApiError('not_found', 404)
        return row

    def get(self, actor, identifier):
        _identifier(identifier)
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_admin(connection, actor)
            row = self._find(connection, identifier)
            return {'inspection': self._public(row, self._read(row))}

    def list(self, actor, *, before=None, limit=10):
        if (type(limit) is not int or not 1 <= limit <= 10 or
                before is not None and (type(before) is not int or not 1 <= before <= 2**63 - 1)):
            raise ApiError('invalid_request')
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_admin(connection, actor)
            rows = connection.execute('SELECT * FROM media_inspections WHERE sequence<? ORDER BY sequence DESC LIMIT ?',
                                      (before if before is not None else 2**63 - 1, limit + 1)).fetchall()
            return {'inspections': [self._public(row, self._read(row)) for row in rows[:limit]],
                    'nextBefore': rows[limit - 1]['sequence'] if len(rows) > limit else None}

    def cancel(self, actor, identifier, body):
        _identifier(identifier)
        with self.db.transaction() as connection:
            self._assert_admin(connection, actor)
            body = _body(body, CancelMediaInspectionRequest)
            row = self._find(connection, identifier)
            payload = self._read(row)
            if row['revision'] != body.expectedRevision:
                raise ApiError('revision_conflict', 409)
            if row['state'] not in ('queued', 'running') or row['cancel_requested']:
                return {'inspection': self._public(row, payload)}
            return self._transition(connection, row, payload,
                                    state='cancelled' if row['state'] == 'queued' else 'running', cancel=True)

    def _dispatch_authorized(self, connection, row):
        current = connection.execute('SELECT u.revision,u.role,u.disabled,u.must_change_password,f.revoked_at,f.expires_at '
                                     'FROM users u JOIN session_families f ON f.user_id=u.id WHERE u.id=? AND f.id=?',
                                     (row['actor_id'], row['family_id'])).fetchone()
        return bool(current and current['revision'] == row['actor_revision'] and current['role'] == 'admin'
                    and not current['disabled'] and not current['must_change_password'] and current['revoked_at'] is None
                    and current['expires_at'] > self.settings.clock())

    def _conditions(self, connection, row, payload):
        if not self._dispatch_authorized(connection, row):
            return 'authority_changed'
        if not self._same_context(payload):
            return 'context_changed'
        preparation = connection.execute('SELECT * FROM media_preparations WHERE id=?', (row['preparation_id'],)).fetchone()
        if preparation is None:
            return 'preparation_changed'
        prepared = self.preparations._decode(preparation)
        if (preparation['state'] != 'prepared' or preparation['revision'] != payload.request.expectedRevision
                or prepared.plan != payload.plan):
            return 'preparation_changed'
        try:
            catalog = load_catalog()
            if catalog.digest != self.preparations.plugins._catalog.digest:
                raise ValueError()
            verify_media_stack_plan(payload.plan, catalog)
        except (ValueError, TypeError, OSError):
            return 'catalog_changed'
        return None

    @contextmanager
    def _dispatch_lock(self):
        descriptor = None
        try:
            descriptor = os.open(self.settings.data_dir / '.media-inspections.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
                raise ApiError('media_inspection_storage_unavailable', 503)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                yield False
                return
            yield True
        except OSError:
            raise ApiError('media_inspection_storage_unavailable', 503) from None
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def tick(self):
        with self._dispatch_lock() as acquired:
            if not acquired:
                return None
            return self._tick_locked()

    def _tick_locked(self):
        with self.db.transaction() as connection:
            row = connection.execute("SELECT * FROM media_inspections WHERE state IN ('queued','running') "
                                     "ORDER BY CASE state WHEN 'running' THEN 0 ELSE 1 END,sequence LIMIT 1").fetchone()
            if row is None:
                return None
            payload = self._decode(row)
            if row['cancel_requested']:
                return self._transition(connection, row, payload, state='cancelled', cancel=True)
            reason = self._conditions(connection, row, payload)
            if reason:
                return self._transition(connection, row, payload, state='needs_attention', error=reason)
            if self.backend is None:
                return self._transition(connection, row, payload, state='failed', error='worker_unavailable')
            self._transition(connection, row, payload, state='running')
            identifier, plan = row['id'], payload.plan
        # SQLite is fully released while the bounded, read-only worker runs.
        result, failure = None, None
        try:
            observed = self.backend.inspect_stack(plan)
        except Exception:
            failure = 'worker_unavailable'
        else:
            try:
                if not isinstance(observed, PreflightResult):
                    raise ValueError()
                result = PreflightResult.model_validate(observed.model_dump(mode='python'))
                if (result.catalogDigest != plan.catalogDigest or result.planHash != plan.planHash or result.platform != plan.platform):
                    raise ValueError()
            except (ValueError, TypeError):
                result, failure = None, 'invalid_worker_result'
        with self.db.transaction() as connection:
            row = self._find(connection, identifier)
            payload = self._decode(row)
            if row['cancel_requested']:
                return self._transition(connection, row, payload, state='cancelled', cancel=True)
            reason = self._conditions(connection, row, payload)
            if reason:
                return self._transition(connection, row, payload, state='needs_attention', error=reason)
            if failure:
                return self._transition(connection, row, payload, state='failed', error=failure)
            return self._transition(connection, row, payload, state='succeeded', result=result)
