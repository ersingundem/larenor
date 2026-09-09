"""Durable S06.4 container-phase coordinator with fresh effect authorization."""

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
from .installation_execution import ExecutionGateResult, build_execution
from .media_installation_models import (
    CancelMediaInstallationRequest, CreateMediaInstallationRequest,
    MediaInstallation, MediaInstallationPayload,
)
from .stack_plan import verify_media_stack_plan


MAX_INSTALLATIONS = 256
MAX_CIPHERTEXT = 131072
BINDING = ('id', 'sequence', 'revision', 'actor_id', 'actor_revision', 'family_id',
           'request_id', 'preparation_id', 'inspection_id', 'state', 'phase',
           'cancel_requested', 'error_code', 'created_at', 'updated_at')
_REQUIRED_CHECKS = frozenset({'platform', 'docker_engine', 'storage_root', 'storage_capacity',
                              'daemon_mount_context', 'daemon_network_context', 'daemon_root_context'})


def _identifier(value):
    if type(value) is not str or re.fullmatch(r'[0-9a-f]{32}', value) is None:
        raise ApiError('invalid_request')


def _body(value, model):
    try:
        return model.model_validate(value.model_dump(mode='python'))
    except (ValueError, TypeError, AttributeError):
        raise ApiError('invalid_request') from None


class MediaInstallationManagement:
    def __init__(self, db, auth, settings, key, preparations, inspections, backend=None):
        self.db, self.auth, self.settings = db, auth, settings
        self.preparations, self.inspections, self.backend = preparations, inspections, backend
        self._cipher = AESGCM(key)

    def _assert_admin(self, connection, actor):
        return self.preparations.plugins._assert_admin(connection, actor)

    @staticmethod
    def _aad(row):
        return b'larenor:media:installations:schema=1:' + json.dumps(
            {key: row[key] for key in BINDING}, sort_keys=True, separators=(',', ':')).encode('ascii')

    def _decode(self, row):
        try:
            for key in ('id', 'actor_id', 'family_id', 'request_id', 'preparation_id', 'inspection_id'):
                if type(row[key]) is not str or re.fullmatch(r'[0-9a-f]{32}', row[key]) is None:
                    raise ValueError()
            if (any(type(row[key]) is not int or not 1 <= row[key] <= 2**63 - 2
                    for key in ('sequence', 'revision', 'actor_revision'))
                    or row['cancel_requested'] not in (0, 1) or len(row['nonce']) != 12
                    or not 16 <= len(row['ciphertext']) <= MAX_CIPHERTEXT):
                raise ValueError()
            payload = MediaInstallationPayload.model_validate_json(
                self._cipher.decrypt(row['nonce'], row['ciphertext'], self._aad(row)))
            request, plan = payload.request, payload.plan
            if (request.requestId != row['request_id'] or request.preparationId != row['preparation_id']
                    or request.inspectionId != row['inspection_id'] or request.planHash != plan.planHash
                    or request.expectedPreparationRevision != 1):
                raise ValueError()
            canonical = json.dumps(plan.model_dump(mode='json', exclude={'planHash'}), sort_keys=True,
                                   separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode('utf-8')
            if hashlib.sha256(canonical).hexdigest() != plan.planHash:
                raise ValueError()
            MediaInstallation.model_validate(self._public(row, payload))
            return payload
        except (InvalidTag, ValueError, TypeError, KeyError, OverflowError, RecursionError):
            raise ApiError('media_installation_storage_unavailable', 503) from None

    def _public(self, row, payload):
        # Historical records remain readable when a later packaged catalog is
        # installed. Dispatch separately re-verifies the current catalog.
        component = next(item for item in payload.plan.components if item.serviceId == 'jellyfin')
        selected = {step.kind: step.stepId for step in component.steps}
        execution = {'serviceId': 'jellyfin', 'operationId': component.operationId,
                     'steps': [{'stepId': selected[kind], 'kind': kind}
                               for kind in ('create_container', 'start_container')]}
        return {'id': row['id'], 'requestId': row['request_id'], 'preparationId': row['preparation_id'],
                'inspectionId': row['inspection_id'], **execution, 'revision': row['revision'],
                'state': row['state'], 'phase': row['phase'],
                'cancelRequested': bool(row['cancel_requested']), 'installAvailable': False,
                'errorCode': row['error_code'], 'createdAt': utc(row['created_at']),
                'updatedAt': utc(row['updated_at'])}

    def _save(self, connection, row, payload):
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(nonce, payload.model_dump_json().encode(), self._aad(row))
        self._decode(dict(row) | {'nonce': nonce, 'ciphertext': ciphertext})
        connection.execute('UPDATE media_installations SET ' + ','.join(key + '=?' for key in BINDING)
                           + ',nonce=?,ciphertext=? WHERE id=?',
                           (*[row[key] for key in BINDING], nonce, ciphertext, row['id']))

    def _transition(self, connection, row, payload, *, state, error=None, cancel=False):
        changed = dict(row)
        changed.update(revision=row['revision'] + 1, state=state,
                       phase='executing' if state == 'running' else 'complete',
                       cancel_requested=int(cancel), error_code=error,
                       updated_at=max(row['updated_at'], int(self.settings.clock())))
        self._save(connection, changed, payload)
        return {'installation': self._public(changed, payload)}

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                connection.execute('BEGIN')
                rows = connection.execute('SELECT * FROM media_installations LIMIT ?',
                                          (MAX_INSTALLATIONS + 1,)).fetchall()
                if len(rows) > MAX_INSTALLATIONS:
                    raise ValueError()
                for row in rows:
                    self._decode(row)
        except (ApiError, ValueError, sqlite3.Error):
            raise StartupError('invalid_media_installations_storage') from None

    def capabilities(self, actor):
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_admin(connection, actor)
            return {'executionConfigured': self.backend is not None,
                    'installAvailable': False, 'services': ['jellyfin']}

    @staticmethod
    def _inspection_passed(payload):
        result = payload.result
        return bool(result and _REQUIRED_CHECKS <= {
            check.code for check in result.checks if check.status == 'passed'})

    def _current_sources(self, connection, body):
        preparation = connection.execute('SELECT * FROM media_preparations WHERE id=?',
                                         (body.preparationId,)).fetchone()
        if preparation is None:
            raise ApiError('not_found', 404)
        prepared = self.preparations._decode(preparation)
        if (preparation['state'] != 'prepared' or preparation['revision'] != body.expectedPreparationRevision
                or prepared.plan.planHash != body.planHash):
            raise ApiError('media_preparation_changed', 409)
        inspection = connection.execute('SELECT * FROM media_inspections WHERE id=?',
                                        (body.inspectionId,)).fetchone()
        if inspection is None:
            raise ApiError('not_found', 404)
        observed = self.inspections._decode(inspection)
        if (inspection['state'] != 'succeeded' or inspection['revision'] != body.expectedInspectionRevision
                or inspection['preparation_id'] != body.preparationId or observed.plan != prepared.plan
                or not self._inspection_passed(observed)):
            raise ApiError('media_inspection_changed', 409)
        return prepared.plan

    def create(self, actor, body):
        with self.db.transaction() as connection:
            actor_revision = self._assert_admin(connection, actor)
            body = _body(body, CreateMediaInstallationRequest)
            previous = connection.execute('SELECT * FROM media_installations WHERE actor_id=? AND request_id=?',
                                          (actor.id, body.requestId)).fetchone()
            if previous:
                payload = self._decode(previous)
                if payload.request != body:
                    raise ApiError('media_installation_conflict', 409)
                return {'installation': self._public(previous, payload)}
            if connection.execute(
                    'SELECT 1 FROM media_installations WHERE preparation_id=?',
                    (body.preparationId,),
            ).fetchone():
                raise ApiError('media_installation_conflict', 409)
            if self.backend is None:
                raise ApiError('plugin_worker_unavailable', 503)
            plan = self._current_sources(connection, body)
            try:
                catalog = load_catalog()
                if catalog.digest != self.preparations.plugins._catalog.digest:
                    raise ValueError()
                verify_media_stack_plan(plan, catalog)
            except (ValueError, TypeError, OSError):
                raise ApiError('media_catalog_changed', 409) from None
            if connection.execute('SELECT COUNT(*) FROM media_installations').fetchone()[0] >= MAX_INSTALLATIONS:
                raise ApiError('media_installation_limit_reached', 409)
            if self._assert_admin(connection, actor) != actor_revision:
                raise ApiError('forbidden', 403)
            now = int(self.settings.clock())
            identifier = uuid.uuid4().hex
            row = {'id': identifier, 'sequence': connection.execute(
                'SELECT COALESCE(MAX(sequence),0)+1 FROM media_installations').fetchone()[0],
                'revision': 1, 'actor_id': actor.id, 'actor_revision': actor_revision,
                'family_id': actor.family_id, 'request_id': body.requestId,
                'preparation_id': body.preparationId, 'inspection_id': body.inspectionId,
                'state': 'queued', 'phase': 'queued', 'cancel_requested': 0,
                'error_code': None, 'created_at': now, 'updated_at': now}
            payload = MediaInstallationPayload(request=body, plan=plan, deadline=now + 30)
            connection.execute('INSERT INTO media_installations(' + ','.join(BINDING)
                               + ',nonce,ciphertext) VALUES(' + ','.join('?' for _ in range(len(BINDING) + 2)) + ')',
                               (*[row[key] for key in BINDING], b'', b''))
            self._save(connection, row, payload)
            return {'installation': self._public(row, payload)}

    @staticmethod
    def _find(connection, identifier):
        row = connection.execute('SELECT * FROM media_installations WHERE id=?', (identifier,)).fetchone()
        if row is None:
            raise ApiError('not_found', 404)
        return row

    def get(self, actor, identifier):
        _identifier(identifier)
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_admin(connection, actor)
            row = self._find(connection, identifier)
            return {'installation': self._public(row, self._decode(row))}

    def list(self, actor, *, before=None, limit=10):
        if (type(limit) is not int or not 1 <= limit <= 10 or
                before is not None and (type(before) is not int or not 1 <= before <= 2**63 - 1)):
            raise ApiError('invalid_request')
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_admin(connection, actor)
            rows = connection.execute('SELECT * FROM media_installations WHERE sequence<? ORDER BY sequence DESC LIMIT ?',
                                      (before or 2**63 - 1, limit + 1)).fetchall()
            return {'installations': [self._public(row, self._decode(row)) for row in rows[:limit]],
                    'nextBefore': rows[limit - 1]['sequence'] if len(rows) > limit else None}

    def cancel(self, actor, identifier, body):
        _identifier(identifier)
        with self.db.transaction() as connection:
            self._assert_admin(connection, actor)
            body = _body(body, CancelMediaInstallationRequest)
            row = self._find(connection, identifier)
            payload = self._decode(row)
            if row['revision'] != body.expectedRevision:
                raise ApiError('revision_conflict', 409)
            if row['state'] not in ('queued', 'running') or row['cancel_requested']:
                return {'installation': self._public(row, payload)}
            return self._transition(connection, row, payload,
                                    state='cancelled' if row['state'] == 'queued' else 'running', cancel=True)

    def _dispatch_authorized(self, connection, row):
        current = connection.execute('SELECT u.revision,u.role,u.disabled,u.must_change_password,f.revoked_at,f.expires_at '
                                     'FROM users u JOIN session_families f ON f.user_id=u.id WHERE u.id=? AND f.id=?',
                                     (row['actor_id'], row['family_id'])).fetchone()
        return bool(current and current['revision'] == row['actor_revision'] and current['role'] == 'admin'
                    and not current['disabled'] and not current['must_change_password'] and current['revoked_at'] is None
                    and current['expires_at'] > self.settings.clock())

    def _gate_locked(self, connection, row, payload):
        if row['cancel_requested']:
            return ExecutionGateResult.denied('cancelled')
        if not self._dispatch_authorized(connection, row):
            return ExecutionGateResult.denied('authority_changed')
        if (payload.plan.coreId != self.preparations.context.coreId
                or payload.plan.homeId != self.preparations.context.homeId):
            return ExecutionGateResult.denied('context_changed')
        try:
            self._current_sources(connection, payload.request)
        except ApiError as error:
            code = 'inspection_changed' if error.code == 'media_inspection_changed' else 'preparation_changed'
            return ExecutionGateResult.denied(code)
        try:
            catalog = load_catalog()
            if catalog.digest != self.preparations.plugins._catalog.digest:
                raise ValueError()
            verify_media_stack_plan(payload.plan, catalog)
        except (ValueError, TypeError, OSError):
            return ExecutionGateResult.denied('catalog_changed')
        return ExecutionGateResult.allowed()

    def _gate(self, identifier):
        try:
            with self.db.connection() as connection:
                connection.execute('BEGIN')
                row = self._find(connection, identifier)
                return self._gate_locked(connection, row, self._decode(row))
        except ApiError:
            return ExecutionGateResult.denied('authority_changed')

    @contextmanager
    def _dispatch_lock(self):
        descriptor = None
        try:
            descriptor = os.open(self.settings.data_dir / '.media-installations.lock',
                                 os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            info = os.fstat(descriptor)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                raise ApiError('media_installation_storage_unavailable', 503)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                yield False
                return
            yield True
        except OSError:
            raise ApiError('media_installation_storage_unavailable', 503) from None
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def tick(self):
        with self._dispatch_lock() as acquired:
            if not acquired:
                return None
            with self.db.transaction() as connection:
                row = connection.execute("SELECT * FROM media_installations WHERE state IN ('queued','running') "
                                         'ORDER BY CASE state WHEN \'running\' THEN 0 ELSE 1 END,sequence LIMIT 1').fetchone()
                if row is None:
                    return None
                payload = self._decode(row)
                gate = self._gate_locked(connection, row, payload)
                if not gate.permitted:
                    return self._transition(connection, row, payload,
                                            state='cancelled' if gate.code == 'cancelled' else 'needs_attention',
                                            error=None if gate.code == 'cancelled' else gate.code,
                                            cancel=gate.code == 'cancelled')
                if self.backend is None:
                    return self._transition(connection, row, payload, state='failed', error='worker_unavailable')
                if row['state'] == 'queued':
                    self._transition(connection, row, payload, state='running')
                identifier = row['id']
            execution = build_execution(payload.plan, job_id=identifier, deadline=payload.deadline)
            outcome = execution.run(self.backend, lambda: self._gate(identifier))
            with self.db.transaction() as connection:
                row = self._find(connection, identifier)
                payload = self._decode(row)
                if row['cancel_requested'] or outcome.state == 'cancelled':
                    return self._transition(connection, row, payload, state='cancelled', cancel=True)
                if outcome.state == 'succeeded':
                    return self._transition(connection, row, payload, state='container_started')
                if outcome.state == 'needs_attention':
                    return self._transition(connection, row, payload, state='needs_attention', error=outcome.code)
                if outcome.state == 'failed':
                    return self._transition(connection, row, payload, state='failed', error=outcome.code)
                return {'installation': self._public(row, payload)}
