"""Resource-authorized, read-only Proxmox summaries.

Every observation is checked against current resource, ACL, user, session,
binding and encrypted service facts both before and after upstream I/O.
"""
from collections import OrderedDict
from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import hmac
import json
import math
import secrets
import sqlite3
import threading
import time
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..admin.service import utc
from ..auth import token_hash
from ..errors import ApiError, StartupError
from . import schema
from .models import Binding, PreviewRequest, Snapshot, Summary
from .transport import read_summary


PREVIEW_TTL = 60.0
CACHE_TTL = 5.0
MAX_PREVIEWS = 32
MAX_ACTOR_PREVIEWS = 4
MAX_CACHE = 256
MAX_USER_CACHE = 32
MAX_CACHE_ENTRY = 65536


@dataclass(frozen=True)
class _Pending:
    actor: object
    body: PreviewRequest
    binding: Binding
    summary: Summary
    fingerprint: tuple
    created: float


@dataclass(frozen=True, repr=False)
class ProxmoxCommandFacts:
    core_id: str
    home_id: str
    resource_id: str
    user_revision: int
    resource_revision: int
    acl_revision: int
    binding_id: str
    binding_revision: int
    service_id: str
    service_revision: int
    fingerprint: tuple


class ProxmoxResourceAdapter:
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
        self._reader = read_summary

    def _now(self):
        now = self._clock()
        if type(now) not in (int, float) or not math.isfinite(now):
            raise ApiError('server_unavailable', 503)
        if self._last_clock is not None and now < self._last_clock:
            self._previews.clear(); self._cache.clear(); self._last_clock = now
            raise ApiError('server_unavailable', 503)
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
            self._previews.clear(); self._cache.clear(); self._closed = True

    @staticmethod
    def _aad(row):
        return f'larenor-proxmox-binding-v1:{row["resource_id"]}:{row["binding_id"]}:{row["revision"]}'.encode()

    def _decode(self, row):
        binding = Binding.model_validate_json(self._cipher.decrypt(
            row['nonce'], row['ciphertext'], self._aad(row)))
        scope = self.resources.scope
        if (binding.id != row['binding_id'] or binding.revision != row['revision'] or
                binding.ref.id != row['resource_id'] or binding.ref.kind != 'resource' or
                (binding.ref.coreId, binding.ref.homeId) != (scope.coreId, scope.homeId)):
            raise ValueError()
        return binding

    def validate_storage(self):
        try:
            with self.db.connection() as c:
                c.execute('BEGIN')
                for row in schema.validate(c, self._key, self.resources.scope):
                    self._decode(row)
        except (ValueError, TypeError, InvalidTag, sqlite3.Error):
            raise StartupError('proxmox_resource_storage_invalid') from None

    @contextmanager
    def _tx(self, actor, core, home, *, admin=False):
        try:
            with self._lock, self.resources._transaction(actor, core, home, admin=admin) as (c, facts):
                if self._closed:
                    raise ApiError('server_unavailable', 503)
                self._now(); schema.validate(c, self._key, self.resources.scope)
                yield c, facts
        except ApiError:
            with self._lock:
                self._cache.clear()
            raise
        except (ValueError, TypeError, InvalidTag, sqlite3.Error):
            with self._lock:
                self._cache.clear()
            raise ApiError('server_unavailable', 503) from None

    def _target(self, c, facts, resource):
        row, ref, data = self.resources._target(c, resource)
        self.resources._require(facts, row, ref, data)
        if ref.kind != 'resource':
            raise ApiError('not_found', 404)
        saved = c.execute('SELECT * FROM proxmox_resource_bindings WHERE resource_id=?',
                          (resource,)).fetchone()
        return row, ref, data, None if saved is None else self._decode(saved)

    def _facts(self, c, facts, resource, body=None):
        row, ref, data, binding = self._target(c, facts, resource)
        if body is not None:
            self.resources._require(facts, row, ref, data,
                expected_revision=body.expectedRevision, expected_acl_revision=body.expectedAclRevision)
            if (None if binding is None else binding.id) != body.expectedBindingId:
                raise ApiError('proxmox_binding_changed', 409)
            service_id, revision = body.serviceId, body.expectedServiceRevision
        else:
            if binding is None:
                raise ApiError('not_found', 404)
            service_id, revision = binding.serviceId, binding.serviceRevision
        try:
            service = self.services._proxmox_connection(c, service_id, revision)
        except ApiError as error:
            if error.code in ('not_found', 'revision_conflict'):
                raise ApiError('proxmox_binding_changed', 409) from None
            raise
        secret = hmac.new(self._key, json.dumps([service.id, service.revision,
            service.base_url, service.name, dict(service.credentials)], sort_keys=True).encode(),
            hashlib.sha256).digest()
        fingerprint = (facts.model_dump_json(), ref.model_dump_json(), row['revision'],
            row['acl_revision'], None if binding is None else binding.model_dump_json(), secret)
        return fingerprint, row, ref, data, binding, service

    def _fresh(self, actor, core, home, resource, fingerprint, body, cancelled, *, admin=False):
        if cancelled():
            raise ApiError('request_timeout', 408)
        with self._tx(actor, core, home, admin=admin) as (c, facts):
            if self._facts(c, facts, resource, body)[0] != fingerprint:
                raise ApiError('proxmox_binding_changed', 409)
        if cancelled():
            raise ApiError('request_timeout', 408)

    def _observe(self, actor, core, home, resource, fingerprint, service, body,
                 cancelled, *, admin=False):
        if cancelled():
            raise ApiError('request_timeout', 408)
        if not self._slots.acquire(blocking=False):
            raise ApiError('proxmox_limit_reached', 429)
        try:
            guard = lambda: self._fresh(actor, core, home, resource, fingerprint,
                                        body, cancelled, admin=admin)
            value = self._reader(service, guard=guard)
            guard()
            try:
                return Summary.model_validate(value)
            except (ValueError, TypeError):
                raise ApiError('proxmox_summary_unsupported', 502) from None
        finally:
            self._slots.release()

    def retire_invalid_session(self, access):
        try:
            digest = token_hash(access)
        except (UnicodeError, AttributeError):
            return
        with self._lock, self.db.connection() as c:
            row = c.execute('SELECT family_id FROM session_tokens WHERE access_hash=?', (digest,)).fetchone()
            if row is not None:
                for key in list(self._cache):
                    if key[-1] == row['family_id']:
                        del self._cache[key]

    def binding(self, actor, core, home, resource):
        with self._tx(actor, core, home, admin=True) as (c, facts):
            value = self._target(c, facts, resource)[3]
            if value is None:
                raise ApiError('not_found', 404)
            return {'binding': value.model_dump()}

    def command_facts(self, actor, core, home, resource):
        """Return private, exact authority facts without service secrets."""
        with self._tx(actor, core, home, admin=True) as (connection, actor_facts):
            fingerprint, row, ref, _, binding, service = self._facts(
                connection, actor_facts, resource
            )
            if binding is None:
                raise ApiError('not_found', 404)
            return ProxmoxCommandFacts(
                core_id=ref.coreId,
                home_id=ref.homeId,
                resource_id=ref.id,
                user_revision=actor_facts.revision,
                resource_revision=row['revision'],
                acl_revision=row['acl_revision'],
                binding_id=binding.id,
                binding_revision=binding.revision,
                service_id=service.id,
                service_revision=service.revision,
                fingerprint=fingerprint,
            )

    def preview(self, actor, core, home, resource, body, *, cancelled=lambda: False):
        body = PreviewRequest.model_validate(body)
        with self._tx(actor, core, home, admin=True) as (c, facts):
            if (len(self._previews) >= MAX_PREVIEWS or
                    sum(p.actor.id == actor.id for p in self._previews.values()) >= MAX_ACTOR_PREVIEWS):
                raise ApiError('proxmox_limit_reached', 429)
            fingerprint, _, ref, _, old, service = self._facts(c, facts, resource, body)
            binding = Binding(id=uuid.uuid4().hex,
                revision=1 if old is None else self.resources._next(old.revision), ref=ref,
                serviceId=service.id, serviceRevision=service.revision)
        summary = self._observe(actor, core, home, resource, fingerprint, service,
                                body, cancelled, admin=True)
        with self._tx(actor, core, home, admin=True) as (c, facts):
            if self._facts(c, facts, resource, body)[0] != fingerprint or cancelled():
                raise ApiError('proxmox_binding_changed', 409)
            identity = uuid.uuid4().hex
            self._previews[identity] = _Pending(actor, body, binding, summary,
                                                 fingerprint, self._now())
            return {'preview': {'id': identity, 'expiresInMs': 60000,
                'binding': binding.model_dump(), 'summary': summary.model_dump()}}

    def _pending(self, actor, resource, preview_id):
        pending = self._previews.get(preview_id)
        if pending is None or pending.actor != actor or pending.binding.ref.id != resource:
            raise ApiError('proxmox_preview_invalid', 409)
        return pending

    def cancel_preview(self, actor, core, home, resource, preview_id):
        with self._tx(actor, core, home, admin=True) as (c, facts):
            self._target(c, facts, resource); self._pending(actor, resource, preview_id)
            del self._previews[preview_id]

    def confirm(self, actor, core, home, resource, preview_id):
        with self._tx(actor, core, home, admin=True) as (c, facts):
            self._target(c, facts, resource)
            pending = self._pending(actor, resource, preview_id)
            del self._previews[preview_id]
            if self._facts(c, facts, resource, pending.body)[0] != pending.fingerprint:
                raise ApiError('proxmox_binding_changed', 409)
            if pending.body.expectedBindingId is None and len(schema.rows(c)) >= schema.MAX_BINDINGS:
                raise ApiError('proxmox_limit_reached', 429)
            binding = pending.binding; nonce = secrets.token_bytes(12)
            plain = binding.model_dump_json().encode()
            row = {'resource_id': resource, 'binding_id': binding.id, 'revision': binding.revision}
            encrypted = self._cipher.encrypt(nonce, plain, self._aad(row))
            if len(encrypted) > schema.MAX_CIPHER:
                raise ApiError('server_unavailable', 503)
            c.execute('INSERT INTO proxmox_resource_bindings VALUES(?,?,?,?,?) ON CONFLICT(resource_id) '
                'DO UPDATE SET binding_id=excluded.binding_id,revision=excluded.revision,'
                'nonce=excluded.nonce,ciphertext=excluded.ciphertext',
                (resource, binding.id, binding.revision, nonce, encrypted))
            schema.update(c, self._key, self.resources.scope)
            saved = c.execute('SELECT * FROM proxmox_resource_bindings WHERE resource_id=?',
                              (resource,)).fetchone()
            if saved is None or self._decode(saved) != binding:
                raise ValueError()
            self._cache.clear()
            return {'binding': binding.model_dump()}

    def snapshot(self, actor, core, home, resource, *, cancelled=lambda: False):
        with self._tx(actor, core, home) as (c, facts):
            fingerprint, row, ref, data, binding, service = self._facts(c, facts, resource)
            key = (core, home, resource, binding.id, binding.revision, service.id,
                   service.revision, actor.id, actor.token_id, actor.family_id)
            now = self._now(); cached = self._cache.get(key)
            if cached is not None and cached[1] == fingerprint and not cancelled():
                remaining = max(0, int((CACHE_TTL - (now - cached[0])) * 1000))
                return {'snapshot': {**cached[2], 'remainingTtlMs': remaining}}
        summary = self._observe(actor, core, home, resource, fingerprint, service,
                                None, cancelled)
        with self._tx(actor, core, home) as (c, facts):
            current, row, ref, data, binding, service = self._facts(c, facts, resource)
            if current != fingerprint or cancelled():
                raise ApiError('proxmox_binding_changed', 409)
            result = Snapshot(ref=ref, bindingId=binding.id, bindingRevision=binding.revision,
                resourceRevision=row['revision'], aclRevision=row['acl_revision'],
                serviceId=service.id, serviceRevision=service.revision,
                observedAt=utc(self.settings.clock()), remainingTtlMs=5000,
                summary=summary).model_dump()
            if len(json.dumps(result, separators=(',', ':')).encode()) > MAX_CACHE_ENTRY:
                raise ApiError('server_unavailable', 503)
            self._cache.pop(key, None)
            while sum(k[7] == actor.id for k in self._cache) >= MAX_USER_CACHE:
                del self._cache[next(k for k in self._cache if k[7] == actor.id)]
            while len(self._cache) >= MAX_CACHE:
                self._cache.popitem(last=False)
            self._cache[key] = (self._now(), fingerprint, result)
            return {'snapshot': result}
