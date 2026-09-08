"""Explicit metadata import, never HA mutation or a cross-device transaction.

Only an explicit current admin confirmation writes a new encrypted service,
one previously unbound resource binding, and its recoverable receipt together.
The Client owns its separate Direct/PIN/tuple checks. This Server does not claim
to authenticate the Client's historical storage or physical HA installation.
"""
from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import hmac
import json
import secrets
from types import MappingProxyType
import uuid

from cryptography.exceptions import InvalidTag

from ..errors import ApiError, StartupError
from ..services.service import MAX_AUDIT_EVENTS, MAX_SERVICES, NEVER, ServiceConnection
from . import schema as ha_schema
from . import migration_schema as schema
from .models import Binding, Projection
from .migration_models import MigrationInput, MigrationConfirm, MigrationReceipt, MigrationPreview, StoredMigration

TTL = 60.0
MAX_PREVIEWS = 32
MAX_ACTOR_PREVIEWS = 4


@dataclass(frozen=True, repr=False)
class _Pending:
    actor: object
    digest: str
    fingerprint: tuple
    preview: MigrationPreview
    created: float


class DirectHaMigration:
    def __init__(self, adapter):
        self.adapter = adapter
        self.resources, self.services = adapter.resources, adapter.services
        self._key, self._cipher = adapter._key, adapter._cipher
        self._previews = {}
        self._last_time = None

    def close(self):
        with self.adapter._lock:
            self._previews.clear()

    @staticmethod
    def _aad(row):
        return f'larenor-direct-ha-migration-v1:{row["request_id"]}:{row["resource_id"]}'.encode('ascii')

    def _decode(self, row):
        value = StoredMigration.model_validate_json(self._cipher.decrypt(row['nonce'], row['ciphertext'], self._aad(row)))
        if (value.receipt.requestId != row['request_id'] or value.receipt.ref.id != row['resource_id'] or
                (value.receipt.ref.coreId, value.receipt.ref.homeId) !=
                (self.resources.scope.coreId, self.resources.scope.homeId)):
            raise ValueError()
        return value

    def validate_storage(self):
        try:
            with self.adapter.db.connection() as c:
                c.execute('BEGIN')
                for row in schema.validate(c, self._key, self.resources.scope):
                    self._decode(row)
        except (ValueError, TypeError, InvalidTag):
            raise StartupError('direct_ha_migration_storage_invalid') from None

    @contextmanager
    def _tx(self, actor, core, home):
        with self.adapter._tx(actor, core, home, admin=True) as (c, facts):
            now = self.adapter._now()
            if self._last_time is not None and now < self._last_time:
                self._previews.clear()
            self._last_time = now
            for identity, pending in list(self._previews.items()):
                if now-pending.created >= TTL:
                    del self._previews[identity]
            schema.validate(c, self._key, self.resources.scope)
            yield c, facts, now

    def _digest(self, body):
        # Keyed equality only, never public metadata or historical-source proof.
        raw = json.dumps(body.model_dump(exclude={'previewId'}), sort_keys=True, separators=(',', ':')).encode()
        return hmac.new(self._key, b'larenor-direct-ha-input-v1\0'+raw, hashlib.sha256).hexdigest()

    def _target(self, c, facts, resource, body=None):
        row, ref, data, binding = self.adapter._target(c, facts, resource)
        if body is not None:
            self.resources._require(facts, row, ref, data, 'write',
                expected_revision=body.expectedRevision, expected_acl_revision=body.expectedAclRevision)
            if binding is not None:
                raise ApiError('ha_migration_changed', 409)
        return row, ref

    def _fingerprint(self, c, facts, resource, body):
        row, ref = self._target(c, facts, resource, body)
        return (facts.model_dump_json(), ref.model_dump_json(), row['revision'], row['acl_revision'])

    def _stored(self, c, actor, resource, request):
        row = c.execute('SELECT * FROM direct_ha_migrations WHERE request_id=?', (request,)).fetchone()
        if row is None:
            return None
        stored = self._decode(row)
        if stored.actorId != actor.id or stored.receipt.ref.id != resource:
            raise ApiError('not_found', 404)
        return stored

    def _capacity(self, c, actor):
        if (len(schema.rows(c)) >= schema.MAX_RECORDS or len(self._previews) >= MAX_PREVIEWS or
                sum(p.actor.id == actor.id for p in self._previews.values()) >= MAX_ACTOR_PREVIEWS):
            raise ApiError('ha_migration_limit_reached', 429)
        if c.execute('SELECT COUNT(*) FROM service_connections').fetchone()[0] >= MAX_SERVICES:
            raise ApiError('service_limit_reached', 409)
        if len(ha_schema.rows(c)) >= ha_schema.MAX_BINDINGS:
            raise ApiError('ha_limit_reached', 429)

    def preview(self, actor, core, home, resource, body, *, cancelled=lambda: False):
        body = MigrationInput.model_validate(body)
        with self._tx(actor, core, home) as (c, facts, _):
            fingerprint = self._fingerprint(c, facts, resource, body)
            if self._stored(c, actor, resource, body.requestId) is not None or any(
                    p.preview.requestId == body.requestId for p in self._previews.values()):
                raise ApiError('ha_migration_changed', 409)
            self._capacity(c, actor)
            _, ref = self._target(c, facts, resource, body)
            service_id, binding_id, preview_id = (uuid.uuid4().hex for _ in range(3))
            binding = Binding(id=binding_id, revision=1, ref=ref, serviceId=service_id,
                              serviceRevision=1, entityId=body.entityId)
            service = ServiceConnection(id=service_id, revision=1, kind='home_assistant', name=body.name,
                base_url=body.baseUrl, credentials=MappingProxyType({'token': body.token}))
            digest = self._digest(body)

        def guard():
            if cancelled():
                raise ApiError('request_timeout', 408)
            with self._tx(actor, core, home) as (c, facts, _):
                if self._fingerprint(c, facts, resource, body) != fingerprint:
                    raise ApiError('ha_migration_changed', 409)
            if cancelled():
                raise ApiError('request_timeout', 408)

        if not self.adapter._slots.acquire(blocking=False):
            raise ApiError('ha_limit_reached', 429)
        try:
            guard()
            projection = Projection.model_validate(self.adapter._reader(service, body.entityId, guard=guard))
            guard()
            projection = projection.model_copy(update={'commandAvailable': False})
        finally:
            self.adapter._slots.release()
        with self._tx(actor, core, home) as (c, facts, now):
            if cancelled() or self._fingerprint(c, facts, resource, body) != fingerprint:
                raise ApiError('ha_migration_changed', 409)
            self._capacity(c, actor)
            if self._stored(c, actor, resource, body.requestId) is not None or any(
                    p.preview.requestId == body.requestId for p in self._previews.values()):
                raise ApiError('ha_migration_changed', 409)
            public = self.services._public(service_id, 1, {'name': body.name, 'kind': 'home_assistant',
                'baseUrl': body.baseUrl, 'credentials': {'token': body.token}, 'verification': NEVER})
            value = MigrationPreview(id=preview_id, requestId=body.requestId, expiresInMs=60000,
                ref=ref, resourceRevision=body.expectedRevision, aclRevision=body.expectedAclRevision,
                service=public, binding=binding, projection=projection)
            self._previews[preview_id] = _Pending(actor, digest, fingerprint, value, now)
            return {'preview': value.model_dump()}

    def cancel(self, actor, core, home, resource, preview_id):
        with self._tx(actor, core, home) as (c, facts, _):
            self._target(c, facts, resource)
            pending = self._previews.get(preview_id)
            if pending is None or pending.actor != actor or pending.preview.ref.id != resource:
                raise ApiError('ha_migration_preview_invalid', 409)
            del self._previews[preview_id]

    def confirm(self, actor, core, home, resource, body):
        body = MigrationConfirm.model_validate(body)
        with self._tx(actor, core, home) as (c, facts, _):
            self._target(c, facts, resource)
            digest = self._digest(body)
            stored = self._stored(c, actor, resource, body.requestId)
            if stored is not None:
                if stored.previewId != body.previewId or not hmac.compare_digest(stored.digest, digest):
                    raise ApiError('ha_migration_changed', 409)
                return {'receipt': stored.receipt.model_dump()}
            pending = self._previews.get(body.previewId)
            if pending is None or pending.actor != actor or pending.preview.ref.id != resource:
                raise ApiError('ha_migration_preview_invalid', 409)
            del self._previews[body.previewId]
            if (not hmac.compare_digest(digest, pending.digest) or
                    self._fingerprint(c, facts, resource, body) != pending.fingerprint):
                raise ApiError('ha_migration_changed', 409)
            self._capacity(c, actor)
            p = pending.preview
            if (c.execute('SELECT 1 FROM service_connections WHERE id=?', (p.service.id,)).fetchone() or
                    c.execute('SELECT 1 FROM home_assistant_bindings WHERE binding_id=?', (p.binding.id,)).fetchone()):
                raise ApiError('ha_migration_changed', 409)
            service = {'name': body.name, 'kind': 'home_assistant', 'baseUrl': body.baseUrl,
                       'credentials': {'token': body.token}, 'verification': dict(NEVER)}
            self.services._save(c, p.service.id, 1, service)
            created = c.execute('SELECT revision FROM service_connections WHERE id=?', (p.service.id,)).fetchone()
            if created is None or created['revision'] != 1:
                raise ValueError()
            if self.services._record(c, p.service.id, 1)[1] != service:
                raise ValueError()
            row = {'resource_id': resource, 'binding_id': p.binding.id, 'revision': 1}
            nonce = secrets.token_bytes(12)
            ciphertext = self._cipher.encrypt(nonce, p.binding.model_dump_json().encode(), self.adapter._aad(row))
            c.execute('INSERT INTO home_assistant_bindings VALUES(?,?,?,?,?)',
                      (resource, p.binding.id, 1, nonce, ciphertext))
            ha_schema.update(c, self._key, self.resources.scope)
            ha_schema.validate(c, self._key, self.resources.scope)
            saved = c.execute('SELECT * FROM home_assistant_bindings WHERE resource_id=?', (resource,)).fetchone()
            if saved is None or self.adapter._decode(saved) != p.binding:
                raise ValueError()
            receipt = MigrationReceipt(requestId=body.requestId, ref=p.ref, resourceRevision=p.resourceRevision,
                aclRevision=p.aclRevision, service=p.service, binding=p.binding)
            stored = StoredMigration(actorId=actor.id, previewId=p.id, digest=digest, receipt=receipt)
            row = {'request_id': body.requestId, 'resource_id': resource}
            nonce = secrets.token_bytes(12)
            ciphertext = self._cipher.encrypt(nonce, stored.model_dump_json().encode(), self._aad(row))
            if len(ciphertext) > schema.MAX_CIPHER:
                raise ValueError()
            c.execute('INSERT INTO direct_ha_migrations VALUES(?,?,?,?)', (body.requestId, resource, nonce, ciphertext))
            schema.update(c, self._key, self.resources.scope)
            schema.validate(c, self._key, self.resources.scope)
            if self._stored(c, actor, resource, body.requestId) != stored:
                raise ValueError()
            c.execute('INSERT INTO service_audit(event,action,status,timestamp,actor_id,target_id) VALUES(?,?,?,?,?,?)',
                      ('admin.service.create', 'create', 'success', self.adapter.settings.clock(), actor.id, p.service.id))
            c.execute('DELETE FROM service_audit WHERE id IN (SELECT id FROM service_audit ORDER BY id DESC LIMIT -1 OFFSET ?)',
                      (MAX_AUDIT_EVENTS,))
            # The last write can have effects too. A receipt acknowledges the
            # complete persisted tuple only after all writes, in this same TX.
            bounds = c.execute("SELECT revision,typeof(nonce),length(nonce),typeof(ciphertext),length(ciphertext) "
                "FROM service_connections WHERE id=?", (p.service.id,)).fetchone()
            if (bounds is None or tuple(bounds[:4]) != (1, 'blob', 12, 'blob') or
                    not 16 <= bounds[4] <= 32768):
                raise ValueError()
            if self.services._record(c, p.service.id, 1)[1] != service:
                raise ValueError()
            ha_schema.validate(c, self._key, self.resources.scope)
            saved = c.execute('SELECT * FROM home_assistant_bindings WHERE resource_id=?', (resource,)).fetchone()
            if saved is None or self.adapter._decode(saved) != p.binding:
                raise ValueError()
            schema.validate(c, self._key, self.resources.scope)
            if self._stored(c, actor, resource, body.requestId) != stored:
                raise ValueError()
            self.adapter._cache.clear()
            return {'receipt': receipt.model_dump()}

    def result(self, actor, core, home, resource, request_id):
        with self._tx(actor, core, home) as (c, facts, _):
            self._target(c, facts, resource)
            value = self._stored(c, actor, resource, request_id)
            if value is None:
                raise ApiError('not_found', 404)
            return {'receipt': value.receipt.model_dump()}
