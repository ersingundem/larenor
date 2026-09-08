"""Resource-authorized HA observations. Previews and cache are process-local.

All current actor, ACL, binding and encrypted service facts are read together
in the registry's SQLite transaction, then checked again after network I/O.
No database transaction or adapter lock spans an upstream request.
"""
from collections import OrderedDict
from contextlib import contextmanager
from dataclasses import dataclass
import json
import hashlib
import hmac
import math
import secrets
import threading
import time
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..admin.service import utc
from ..auth import token_hash
from ..errors import ApiError, StartupError
from . import schema
from .models import Binding, PreviewRequest, Projection, Snapshot
from .transport import read_switch


PREVIEW_TTL = 60.0
CACHE_TTL = 5.0
MAX_PREVIEWS = 32
MAX_ACTOR_PREVIEWS = 4
MAX_CACHE = 256
MAX_USER_CACHE = 32
MAX_CACHE_ENTRY = 2048


@dataclass(frozen=True)
class _Pending:
    actor: object
    body: PreviewRequest
    binding: Binding
    projection: Projection
    fingerprint: tuple
    created: float


class HomeAssistantAdapter:
    def __init__(self, db, auth, settings, key, resources, services):
        self.db, self.auth, self.settings = db, auth, settings
        self.resources, self.services = resources, services
        self._key, self._cipher = key, AESGCM(key)
        self._lock = threading.RLock()
        self._previews = {}
        self._cache = OrderedDict()
        self._clock = time.monotonic
        self._last_clock = None
        self._closed = False
        self._slots = threading.BoundedSemaphore(4)
        self._reader = read_switch  # Private packaged/test seam, never an HTTP option.

    def _now(self):
        now = self._clock()
        if type(now) not in (int, float) or not math.isfinite(now):
            raise ApiError('server_unavailable', 503)
        if self._last_clock is not None and now < self._last_clock:
            self._previews.clear(); self._cache.clear()
        self._last_clock = now
        for key, pending in list(self._previews.items()):
            if now - pending.created >= PREVIEW_TTL:
                del self._previews[key]
        for key, value in list(self._cache.items()):
            if now - value[0] >= CACHE_TTL:
                del self._cache[key]
        return now

    def close(self):
        with self._lock:
            self._previews.clear(); self._cache.clear()
            self._closed = True

    @staticmethod
    def _aad(row):
        return f'larenor-ha-binding-v1:{row["resource_id"]}:{row["binding_id"]}:{row["revision"]}'.encode('ascii')

    def _decode(self, row):
        binding = Binding.model_validate_json(self._cipher.decrypt(row['nonce'], row['ciphertext'], self._aad(row)))
        if (binding.id != row['binding_id'] or binding.revision != row['revision'] or
                binding.ref.id != row['resource_id'] or binding.ref.kind != 'resource' or
                (binding.ref.coreId, binding.ref.homeId) != (self.resources.scope.coreId, self.resources.scope.homeId)):
            raise ValueError()
        return binding

    def validate_storage(self):
        try:
            with self.db.connection() as c:
                c.execute('BEGIN')
                for row in schema.validate(c, self._key, self.resources.scope):
                    self._decode(row)
        except (ValueError, TypeError, InvalidTag):
            raise StartupError('home_assistant_storage_invalid') from None

    @contextmanager
    def _tx(self, actor, core, home, *, admin=False):
        try:
            with self._lock, self.resources._transaction(actor, core, home, admin=admin) as (c, facts):
                if self._closed:
                    raise ApiError("server_unavailable", 503)
                self._now()
                schema.validate(c, self._key, self.resources.scope)
                yield c, facts
        except ApiError:
            with self._lock:
                # Known source/authority failure retires observations immediately.
                self._cache.clear()
            raise

    def _target(self, c, facts, resource):
        row, ref, data = self.resources._target(c, resource)
        self.resources._require(facts, row, ref, data)
        if ref.kind != 'resource':
            raise ApiError('not_found', 404)
        saved = c.execute('SELECT * FROM home_assistant_bindings WHERE resource_id=?', (resource,)).fetchone()
        return row, ref, data, None if saved is None else self._decode(saved)

    def _facts(self, c, facts, resource, body=None):
        row, ref, data, binding = self._target(c, facts, resource)
        if body is not None:
            self.resources._require(facts, row, ref, data,
                expected_revision=body.expectedRevision, expected_acl_revision=body.expectedAclRevision)
            if (None if binding is None else binding.id) != body.expectedBindingId:
                raise ApiError('ha_binding_changed', 409)
            service_id, revision = body.serviceId, body.expectedServiceRevision
        else:
            if binding is None:
                raise ApiError('not_found', 404)
            service_id, revision = binding.serviceId, binding.serviceRevision
        try:
            service = self.services._home_assistant_connection(c, service_id, revision)
        except ApiError as error:
            if body is None and error.code in ('not_found', 'revision_conflict'):
                raise ApiError('ha_binding_changed', 409) from None
            raise
        fingerprint = (facts.model_dump_json(), ref.model_dump_json(), row['revision'], row['acl_revision'],
            None if binding is None else binding.model_dump_json(), hmac.new(self._key,
                json.dumps([service.id, service.revision, service.base_url, service.name,
                    dict(service.credentials)], sort_keys=True).encode(), hashlib.sha256).digest())
        return fingerprint, row, ref, binding, service

    def _fresh(self, actor, core, home, resource, fingerprint, body, cancelled, *, admin=False):
        if cancelled():
            raise ApiError('request_timeout', 408)
        with self._tx(actor, core, home, admin=admin) as (c, facts):
            current = self._facts(c, facts, resource, body)[0]
            if current != fingerprint:
                raise ApiError('ha_binding_changed', 409)
        if cancelled():
            raise ApiError('request_timeout', 408)

    def _observe(self, actor, core, home, resource, fingerprint, service, entity, body, cancelled, *, admin=False):
        if not self._slots.acquire(blocking=False):
            raise ApiError('ha_limit_reached', 429)
        try:
            def guard():
                self._fresh(actor, core, home, resource, fingerprint, body, cancelled, admin=admin)
            projection = self._reader(service, entity, guard=guard)
            guard()
            # Even trusted replacement readers cannot smuggle arbitrary attributes.
            return Projection.model_validate(projection)
        finally:
            self._slots.release()

    def retire_invalid_session(self, access):
        """Discard this known token family's cache after authentication rejects it.

        Only a token hash is looked up. Unknown tokens cannot purge other users;
        no authentication grant or raw token is retained in the cache.
        """
        try:
            digest = token_hash(access)
        except (UnicodeError, AttributeError):
            return
        with self._lock, self.db.connection() as c:
            row = c.execute('SELECT family_id FROM session_tokens WHERE access_hash=?', (digest,)).fetchone()
            if row is not None:
                for key in list(self._cache):
                    if key[6] == row['family_id']:
                        del self._cache[key]

    def binding(self, actor, core, home, resource):
        with self._tx(actor, core, home, admin=True) as (c, facts):
            binding = self._target(c, facts, resource)[3]
            if binding is None:
                raise ApiError('not_found', 404)
            return {'binding': binding.model_dump()}

    def preview(self, actor, core, home, resource, body, *, cancelled=lambda: False):
        body = PreviewRequest.model_validate(body)
        with self._tx(actor, core, home, admin=True) as (c, facts):
            if len(self._previews) >= MAX_PREVIEWS or sum(p.actor.id == actor.id for p in self._previews.values()) >= MAX_ACTOR_PREVIEWS:
                raise ApiError('ha_limit_reached', 429)
            fingerprint, row, ref, old, service = self._facts(c, facts, resource, body)
            revision = 1 if old is None else self.resources._next(old.revision)
            proposed = Binding(id=uuid.uuid4().hex, revision=revision, ref=ref,
                serviceId=service.id, serviceRevision=service.revision, entityId=body.entityId)
        projection = self._observe(actor, core, home, resource, fingerprint, service, body.entityId, body, cancelled, admin=True)
        with self._tx(actor, core, home, admin=True) as (c, facts):
            if self._facts(c, facts, resource, body)[0] != fingerprint or cancelled():
                raise ApiError('ha_binding_changed', 409)
            if len(self._previews) >= MAX_PREVIEWS or sum(p.actor.id == actor.id for p in self._previews.values()) >= MAX_ACTOR_PREVIEWS:
                raise ApiError('ha_limit_reached', 429)
            identity = uuid.uuid4().hex
            self._previews[identity] = _Pending(actor, body, proposed, projection, fingerprint, self._now())
            return {'preview': {'id': identity, 'expiresInMs': 60000, 'binding': proposed.model_dump(), 'projection': projection.model_dump()}}

    def _pending(self, actor, resource, preview_id):
        pending = self._previews.get(preview_id)
        if pending is None or pending.actor != actor or pending.binding.ref.id != resource:
            raise ApiError('ha_preview_invalid', 409)
        return pending

    def cancel_preview(self, actor, core, home, resource, preview_id):
        with self._tx(actor, core, home, admin=True) as (c, facts):
            self._target(c, facts, resource)
            self._pending(actor, resource, preview_id)
            del self._previews[preview_id]

    def _prune_deleted(self, c):
        """Remove only orphan binding metadata within an admin confirm transaction.

        Both inventories must validate completely before the first deletion.
        The caller's transaction also owns the replacement write and HA HMAC
        updates, so any failed confirmation rolls all cleanup back.
        """
        live = self.resources._validated_ids(c)
        rows = schema.validate(c, self._key, self.resources.scope)
        for row in rows:
            self._decode(row)
        deleted = [row['resource_id'] for row in rows if row['resource_id'] not in live]
        if deleted:
            c.executemany('DELETE FROM home_assistant_bindings WHERE resource_id=?',
                          ((identity,) for identity in deleted))
            schema.update(c, self._key, self.resources.scope)

    def confirm(self, actor, core, home, resource, preview_id):
        with self._tx(actor, core, home, admin=True) as (c, facts):
            self._target(c, facts, resource)
            pending = self._pending(actor, resource, preview_id)
            # Consume once even if the subsequent CAS/storage operation fails.
            del self._previews[preview_id]
            if self._facts(c, facts, resource, pending.body)[0] != pending.fingerprint:
                raise ApiError('ha_binding_changed', 409)
            binding = pending.binding
            self._prune_deleted(c)
            if pending.body.expectedBindingId is None and len(schema.rows(c)) >= schema.MAX_BINDINGS:
                raise ApiError('ha_limit_reached', 429)
            plain = binding.model_dump_json().encode('utf-8'); nonce = secrets.token_bytes(12)
            row = {'resource_id': resource, 'binding_id': binding.id, 'revision': binding.revision}
            cipher = self._cipher.encrypt(nonce, plain, self._aad(row))
            if len(cipher) > schema.MAX_CIPHER:
                raise ApiError('server_unavailable', 503)
            c.execute('INSERT INTO home_assistant_bindings VALUES(?,?,?,?,?) ON CONFLICT(resource_id) DO UPDATE SET '
                'binding_id=excluded.binding_id,revision=excluded.revision,nonce=excluded.nonce,ciphertext=excluded.ciphertext',
                (resource, binding.id, binding.revision, nonce, cipher))
            schema.update(c, self._key, self.resources.scope)
            schema.validate(c, self._key, self.resources.scope)
            saved = c.execute('SELECT * FROM home_assistant_bindings WHERE resource_id=?', (resource,)).fetchone()
            if saved is None or self._decode(saved) != binding:
                raise ValueError()
            self._cache.clear()
            return {'binding': binding.model_dump()}

    def snapshot(self, actor, core, home, resource, *, cancelled=lambda: False):
        with self._tx(actor, core, home) as (c, facts):
            fingerprint, row, ref, binding, service = self._facts(c, facts, resource)
            key = (core, home, actor.id, actor.token_id, resource, binding.id, actor.family_id)
            now = self._now(); cached = self._cache.get(key)
            if cached is not None and cached[1] == fingerprint and not cancelled():
                remaining = max(0, int((CACHE_TTL - (now - cached[0])) * 1000))
                return {'snapshot': {**cached[2], 'remainingTtlMs': remaining}}
        projection = self._observe(actor, core, home, resource, fingerprint, service, binding.entityId, None, cancelled)
        with self._tx(actor, core, home) as (c, facts):
            current, row, ref, binding, _ = self._facts(c, facts, resource)
            if current != fingerprint or cancelled():
                raise ApiError('ha_binding_changed', 409)
            result = Snapshot(ref=ref, bindingId=binding.id, bindingRevision=binding.revision,
                resourceRevision=row['revision'], aclRevision=row['acl_revision'], serviceRevision=binding.serviceRevision,
                observedAt=utc(self.settings.clock()), remainingTtlMs=5000, projection=projection).model_dump()
            if len(json.dumps(result).encode('utf-8')) > MAX_CACHE_ENTRY:
                raise ApiError('server_unavailable', 503)
            self._cache.pop(key, None)
            while sum(k[2] == actor.id for k in self._cache) >= MAX_USER_CACHE:
                del self._cache[next(k for k in self._cache if k[2] == actor.id)]
            while len(self._cache) >= MAX_CACHE:
                self._cache.popitem(last=False)
            self._cache[key] = (self._now(), fingerprint, result)
            return {'snapshot': result}
