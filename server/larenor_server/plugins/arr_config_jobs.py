"""Encrypted, durable Arr config coordination with no automatic retry."""

from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import json
import os
import re
import secrets
import sqlite3
import stat
import time
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..admin.service import utc
from ..errors import ApiError, StartupError
from .catalog import load_catalog
from .installation_execution import ExecutionGateResult
from .arr_config_effect import ArrConfigInstallReceipt
from .arr_config_job_models import (
    CancelArrConfigurationRequest,
    CreateArrConfigurationRequest,
    PrivateArrReceipt, ArrConfiguration,
    ArrConfigurationPayload,
)
from .arr_config_models import (
    ArrConfiguredInstallReceipt, PrivateArrConfiguration,
    ArrConfigurationExecutionError,
)
from .arr_owned_config import generate_arr_api_key
from .stack_plan import verify_media_stack_plan


MAX_CONFIGURATIONS = 256
MAX_CIPHERTEXT = 131072
_BINDING = (
    'id', 'sequence', 'revision', 'actor_id', 'actor_revision', 'family_id',
    'request_id', 'preparation_id', 'inspection_id', 'service_id', 'state', 'phase',
    'cancel_requested', 'error_code', 'configuration_state', 'created_at',
    'updated_at',
)


@dataclass(frozen=True, repr=False)
class _PrivateView:
    service_id: str
    api_key: str
    receipt: ArrConfiguredInstallReceipt | None

    def __repr__(self):
        return '_PrivateView(<private>)'


def _identifier(value):
    if type(value) is not str or re.fullmatch(r'[0-9a-f]{32}', value) is None:
        raise ApiError('invalid_request')


def _body(value, model):
    try:
        return model.model_validate(value.model_dump(mode='python'))
    except (ValidationError, ValueError, TypeError, AttributeError):
        raise ApiError('invalid_request') from None


class ArrConfigurationManagement:
    def __init__(self, db, auth, settings, key, installations, backend=None,
                 qbittorrent=None):
        self.db, self.auth, self.settings = db, auth, settings
        self.installations, self.backend = installations, backend
        self.qbittorrent = qbittorrent
        self._cipher = AESGCM(key)

    def _assert_admin(self, connection, actor):
        return self.installations._assert_admin(connection, actor)

    @staticmethod
    def _aad(row):
        return b'larenor:media:arr-configurations:schema=1:' + json.dumps(
            {key: row[key] for key in _BINDING},
            sort_keys=True, separators=(',', ':')).encode('ascii')

    @staticmethod
    def _public(row):
        return ArrConfiguration.model_validate({
            'id': row['id'], 'requestId': row['request_id'],
            'preparationId': row['preparation_id'],
            'inspectionId': row['inspection_id'], 'serviceId': row['service_id'],
            'revision': row['revision'], 'state': row['state'],
            'phase': row['phase'], 'cancelRequested': bool(row['cancel_requested']),
            'configured': row['state'] == 'succeeded',
            'configurationState': row['configuration_state'],
            'containerState': ('container_started' if row['state'] == 'succeeded' else None),
            'serviceState': ('verified' if row['state'] == 'succeeded' else None),
            'errorCode': row['error_code'], 'installAvailable': False,
            'createdAt': utc(row['created_at']), 'updatedAt': utc(row['updated_at']),
        }).model_dump()

    def _decode(self, row):
        try:
            if (len(row['nonce']) != 12
                    or not 16 <= len(row['ciphertext']) <= MAX_CIPHERTEXT
                    or row['cancel_requested'] not in (0, 1)
                    or any(type(row[key]) is not int or not 1 <= row[key] <= 2**63 - 2
                           for key in ('sequence', 'revision', 'actor_revision'))
                    or any(type(row[key]) is not int
                           or not 0 <= row[key] <= 253402300799
                           for key in ('created_at', 'updated_at'))
                    or row['updated_at'] < row['created_at']
                    or any(type(row[key]) is not str
                           or re.fullmatch(r'[0-9a-f]{32}', row[key]) is None
                           for key in ('id', 'actor_id', 'family_id', 'request_id',
                                       'preparation_id', 'inspection_id'))
                    or row['service_id'] not in {'sonarr', 'radarr'}):
                raise ValueError()
            payload = ArrConfigurationPayload.model_validate_json(
                self._cipher.decrypt(row['nonce'], row['ciphertext'], self._aad(row)))
            request = payload.request
            if (request.requestId != row['request_id']
                    or request.preparationId != row['preparation_id']
                    or request.inspectionId != row['inspection_id']
                    or request.serviceId != row['service_id']
                    or payload.private.serviceId != row['service_id']
                    or request.planHash != payload.plan.planHash):
                raise ValueError()
            canonical = json.dumps(
                payload.plan.model_dump(mode='json', exclude={'planHash'}),
                sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                allow_nan=False).encode('utf-8')
            if hashlib.sha256(canonical).hexdigest() != payload.plan.planHash:
                raise ValueError()
            if ((payload.receipt is None) != (row['state'] != 'succeeded')
                    or payload.receipt is not None
                    and payload.receipt.state != row['configuration_state']):
                raise ValueError()
            self._public(row)
            return payload
        except (InvalidTag, ValidationError, ValueError, TypeError, AttributeError,
                KeyError, OverflowError, RecursionError):
            raise ApiError('media_arr_configuration_storage_unavailable', 503) from None

    def _validate_row(self, connection, row):
        payload = self._decode(row)
        preparation = connection.execute(
            'SELECT * FROM media_preparations WHERE id=?',
            (row['preparation_id'],)).fetchone()
        inspection = connection.execute(
            'SELECT * FROM media_inspections WHERE id=?',
            (row['inspection_id'],)).fetchone()
        try:
            if preparation is None or inspection is None:
                raise ValueError()
            prepared = self.installations.preparations._decode(preparation)
            observed = self.installations.inspections._decode(inspection)
            if (prepared.plan != payload.plan or observed.plan != payload.plan
                    or inspection['preparation_id'] != row['preparation_id']):
                raise ValueError()
        except (ApiError, ValueError, TypeError, AttributeError):
            raise ApiError(
                'media_arr_configuration_storage_unavailable', 503) from None
        return payload

    def _save(self, connection, row, payload):
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(
            nonce, payload.model_dump_json().encode('utf-8'), self._aad(row))
        if len(ciphertext) > MAX_CIPHERTEXT:
            raise ApiError('media_arr_configuration_storage_unavailable', 503)
        self._decode(dict(row) | {'nonce': nonce, 'ciphertext': ciphertext})
        connection.execute(
            'UPDATE media_arr_configurations SET '
            + ','.join(key + '=?' for key in _BINDING)
            + ',nonce=?,ciphertext=? WHERE id=?',
            (*[row[key] for key in _BINDING], nonce, ciphertext, row['id']))

    def _transition(self, connection, row, payload, *, state, error=None,
                    receipt=None, cancel=False):
        changed = dict(row)
        changed.update(
            revision=row['revision'] + 1, state=state,
            phase='configuring' if state == 'running' else 'complete',
            cancel_requested=int(cancel or row['cancel_requested']),
            error_code=error,
            configuration_state=None if receipt is None else receipt.state,
            updated_at=max(row['updated_at'], int(self.settings.clock())),
        )
        value = payload.model_copy(update={'receipt': receipt})
        self._save(connection, changed, value)
        return {'configuration': self._public(changed)}

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                connection.execute('BEGIN')
                rows = connection.execute(
                    'SELECT * FROM media_arr_configurations LIMIT ?',
                    (MAX_CONFIGURATIONS + 1,)).fetchall()
                if len(rows) > MAX_CONFIGURATIONS:
                    raise ValueError()
                for row in rows:
                    self._validate_row(connection, row)
        except (ApiError, ValueError, sqlite3.Error):
            raise StartupError('invalid_media_arr_configurations_storage') from None

    def capabilities(self, actor):
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_admin(connection, actor)
            return {'executionConfigured': self.backend is not None,
                    'installAvailable': False,
                    'serviceIds': ('sonarr', 'radarr')}

    def create(self, actor, body):
        body = _body(body, CreateArrConfigurationRequest)
        with self.db.transaction() as connection:
            actor_revision = self._assert_admin(connection, actor)
            previous = connection.execute(
                'SELECT * FROM media_arr_configurations '
                'WHERE actor_id=? AND request_id=?',
                (actor.id, body.requestId)).fetchone()
            if previous is not None:
                payload = self._decode(previous)
                if payload.request != body:
                    raise ApiError('media_arr_configuration_conflict', 409)
                return {'configuration': self._public(previous)}
            if self.backend is None:
                raise ApiError('plugin_worker_unavailable', 503)
            if self.qbittorrent is None:
                raise ApiError('media_qbittorrent_configuration_required', 409)
            if connection.execute(
                'SELECT 1 FROM media_arr_configurations '
                'WHERE preparation_id=? AND service_id=?',
                    (body.preparationId, body.serviceId)).fetchone() is not None:
                raise ApiError('media_arr_configuration_conflict', 409)
            plan = self.installations._current_sources(connection, body)
            try:
                catalog = load_catalog()
                if catalog.digest != self.installations.preparations.plugins._catalog.digest:
                    raise ValueError()
                plan = verify_media_stack_plan(plan, catalog)
            except (ValueError, TypeError, AttributeError, OSError):
                raise ApiError('media_catalog_changed', 409) from None
            if connection.execute(
                    'SELECT COUNT(*) FROM media_arr_configurations').fetchone()[0] >= MAX_CONFIGURATIONS:
                raise ApiError('media_arr_configuration_limit_reached', 409)
            if self._assert_admin(connection, actor) != actor_revision:
                raise ApiError('forbidden', 403)
            now = int(self.settings.clock())
            row = {
                'id': uuid.uuid4().hex,
                'sequence': connection.execute(
                    'SELECT COALESCE(MAX(sequence),0)+1 FROM media_arr_configurations').fetchone()[0],
                'revision': 1, 'actor_id': actor.id,
                'actor_revision': actor_revision, 'family_id': actor.family_id,
                'request_id': body.requestId, 'preparation_id': body.preparationId,
                'inspection_id': body.inspectionId, 'service_id': body.serviceId,
                'state': 'queued',
                'phase': 'queued', 'cancel_requested': 0, 'error_code': None,
                'configuration_state': None, 'created_at': now, 'updated_at': now,
            }
            dependency = self.qbittorrent.arr_dependency(body.preparationId)
            private = PrivateArrConfiguration(
                serviceId=body.serviceId, apiKey=generate_arr_api_key(),
                qbittorrentApiKey=dependency.api_key)
            payload = ArrConfigurationPayload(
                request=body, plan=plan, private=private)
            connection.execute(
                'INSERT INTO media_arr_configurations('
                + ','.join(_BINDING) + ',nonce,ciphertext) VALUES('
                + ','.join('?' for _ in range(len(_BINDING) + 2)) + ')',
                (*[row[key] for key in _BINDING], b'', b''))
            self._save(connection, row, payload)
            return {'configuration': self._public(row)}

    @staticmethod
    def _find(connection, identifier):
        row = connection.execute(
            'SELECT * FROM media_arr_configurations WHERE id=?',
            (identifier,)).fetchone()
        if row is None:
            raise ApiError('not_found', 404)
        return row

    def get(self, actor, identifier):
        _identifier(identifier)
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_admin(connection, actor)
            row = self._find(connection, identifier)
            self._validate_row(connection, row)
            return {'configuration': self._public(row)}

    def list(self, actor, *, before=None, limit=10):
        if (type(limit) is not int or not 1 <= limit <= 10
                or before is not None
                and (type(before) is not int or not 1 <= before <= 2**63 - 1)):
            raise ApiError('invalid_request')
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            self._assert_admin(connection, actor)
            rows = connection.execute(
                'SELECT * FROM media_arr_configurations WHERE sequence<? '
                'ORDER BY sequence DESC LIMIT ?',
                (before or 2**63 - 1, limit + 1)).fetchall()
            for row in rows:
                self._validate_row(connection, row)
            return {'configurations': [self._public(row) for row in rows[:limit]],
                    'nextBefore': rows[limit - 1]['sequence'] if len(rows) > limit else None}

    def cancel(self, actor, identifier, body):
        _identifier(identifier)
        body = _body(body, CancelArrConfigurationRequest)
        with self.db.transaction() as connection:
            self._assert_admin(connection, actor)
            row = self._find(connection, identifier)
            payload = self._decode(row)
            if row['revision'] != body.expectedRevision:
                raise ApiError('revision_conflict', 409)
            if row['state'] not in {'queued', 'running'} or row['cancel_requested']:
                return {'configuration': self._public(row)}
            return self._transition(
                connection, row, payload,
                state='cancelled' if row['state'] == 'queued' else 'running',
                cancel=True)

    def private_payload(self, identifier):
        _identifier(identifier)
        with self.db.connection() as connection:
            connection.execute('BEGIN')
            payload = self._validate_row(
                connection, self._find(connection, identifier))
        receipt = None if payload.receipt is None else ArrConfigInstallReceipt(
            payload.receipt.serviceId, payload.receipt.resourceId,
            payload.receipt.operationId,
            payload.receipt.journalId, payload.receipt.revision,
            payload.receipt.volumeName, payload.receipt.configurationDigest,
            payload.receipt.state)
        if receipt is not None:
            receipt = ArrConfiguredInstallReceipt(
                receipt, payload.receipt.containerId,
                payload.receipt.containerState, payload.receipt.serviceState)
        return _PrivateView(
            payload.private.serviceId, payload.private.apiKey, receipt)

    def _dispatch_authorized(self, connection, row):
        current = connection.execute(
            'SELECT u.revision,u.role,u.disabled,u.must_change_password,'
            'f.revoked_at,f.expires_at FROM users u JOIN session_families f '
            'ON f.user_id=u.id WHERE u.id=? AND f.id=?',
            (row['actor_id'], row['family_id'])).fetchone()
        return bool(
            current and current['revision'] == row['actor_revision']
            and current['role'] == 'admin' and not current['disabled']
            and not current['must_change_password'] and current['revoked_at'] is None
            and current['expires_at'] > self.settings.clock())

    def _gate_locked(self, connection, row, payload):
        if row['cancel_requested']:
            return ExecutionGateResult.denied('cancelled')
        if not self._dispatch_authorized(connection, row):
            return ExecutionGateResult.denied('authority_changed')
        if (payload.plan.coreId != self.installations.preparations.context.coreId
                or payload.plan.homeId != self.installations.preparations.context.homeId):
            return ExecutionGateResult.denied('context_changed')
        try:
            self.installations._current_sources(connection, payload.request)
        except ApiError as error:
            code = ('inspection_changed'
                    if error.code == 'media_inspection_changed'
                    else 'preparation_changed')
            return ExecutionGateResult.denied(code)
        try:
            catalog = load_catalog()
            if catalog.digest != self.installations.preparations.plugins._catalog.digest:
                raise ValueError()
            verify_media_stack_plan(payload.plan, catalog)
        except (ValueError, TypeError, AttributeError, OSError):
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
            descriptor = os.open(
                self.settings.data_dir / '.arr-configurations.lock',
                os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            info = os.fstat(descriptor)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                raise ApiError('media_arr_configuration_storage_unavailable', 503)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                yield False
                return
            yield True
        except OSError:
            raise ApiError('media_arr_configuration_storage_unavailable', 503) from None
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def tick(self):
        with self._dispatch_lock() as acquired:
            if not acquired:
                return None
            with self.db.transaction() as connection:
                row = connection.execute(
                    "SELECT * FROM media_arr_configurations "
                    "WHERE state IN ('queued','running') "
                    "ORDER BY CASE state WHEN 'running' THEN 0 ELSE 1 END,sequence LIMIT 1",
                ).fetchone()
                if row is None:
                    return None
                payload = self._decode(row)
                if row['state'] == 'running' and not row['cancel_requested']:
                    return self._transition(
                        connection, row, payload, state='needs_attention',
                        error='arr_config_interrupted')
                gate = self._gate_locked(connection, row, payload)
                if not gate.permitted:
                    if gate.code == 'cancelled' and row['state'] == 'queued':
                        return self._transition(
                            connection, row, payload, state='cancelled', cancel=True)
                    return self._transition(
                        connection, row, payload, state='needs_attention',
                        error=('arr_config_cancellation_uncertain'
                               if gate.code == 'cancelled'
                               else 'arr_config_' + gate.code),
                        cancel=gate.code == 'cancelled')
                if self.backend is None:
                    return self._transition(
                        connection, row, payload, state='failed',
                        error='arr_config_worker_unavailable')
                self._transition(connection, row, payload, state='running')
                identifier = row['id']
            try:
                result = self.backend.install_arr(
                    identifier, payload.plan, payload.private,
                    deadline=time.monotonic() + 30.0,
                    gate=lambda: self._gate(identifier).permitted)
                if type(result) is not ArrConfiguredInstallReceipt:
                    raise ArrConfigurationExecutionError(
                        'arr_config_result_invalid', uncertain_effect=True)
                receipt = PrivateArrReceipt(
                    serviceId=payload.private.serviceId,
                    resourceId=result.configuration.resource_id,
                    operationId=result.configuration.operation_id,
                    journalId=result.configuration.journal_id,
                    revision=result.configuration.revision,
                    volumeName=result.configuration.volume_name,
                    configurationDigest=result.configuration.configuration_digest,
                    state=result.configuration.state,
                    containerId=result.container_id,
                    containerState=result.state,
                    serviceState=result.service_state)
            except ArrConfigurationExecutionError as failure:
                with self.db.transaction() as connection:
                    row = self._find(connection, identifier)
                    payload = self._decode(row)
                    cancelled = bool(row['cancel_requested'])
                    state = ('needs_attention' if cancelled
                             or failure.uncertain_effect
                             or failure.code == 'arr_config_authority_changed'
                             else 'failed')
                    error = ('arr_config_cancellation_uncertain'
                             if cancelled else failure.code)
                    return self._transition(
                        connection, row, payload, state=state, error=error,
                        cancel=cancelled)
            except (OSError, ValueError, TypeError, AttributeError, RuntimeError):
                with self.db.transaction() as connection:
                    row = self._find(connection, identifier)
                    return self._transition(
                        # The worker may have completed the filesystem effect
                        # before its response was lost. Require inspection
                        # instead of claiming the configuration is untouched.
                        connection, row, self._decode(row), state='needs_attention',
                        error='arr_config_worker_unavailable')
            with self.db.transaction() as connection:
                row = self._find(connection, identifier)
                payload = self._decode(row)
                if row['cancel_requested']:
                    return self._transition(
                        connection, row, payload, state='needs_attention',
                        error='arr_config_cancellation_uncertain', cancel=True)
                gate = self._gate_locked(connection, row, payload)
                if not gate.permitted:
                    return self._transition(
                        connection, row, payload, state='needs_attention',
                        error='arr_config_' + gate.code)
                return self._transition(
                    connection, row, payload, state='succeeded', receipt=receipt)
