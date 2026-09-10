"""Resource-authorized Keenetic observations with process-local previews/cache."""
import hashlib
import hmac
import json
import math
import secrets
import threading
import time
import uuid
from collections import OrderedDict
from contextlib import contextmanager
from dataclasses import dataclass

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..admin.service import utc
from ..auth import token_hash
from ..errors import ApiError, StartupError
from . import schema
from .models import BindingPreviewRequest, KeeneticBinding, ResourceSnapshot, Telemetry
from .transport import read_telemetry

PREVIEW_TTL = 60.0
CACHE_TTL = 5.0
MAX_PREVIEWS = 32
MAX_ACTOR_PREVIEWS = 4
MAX_CACHE = 128
MAX_USER_CACHE = 16
MAX_CACHE_ENTRY = 65536
OPERATION_TTL = 10.0


@dataclass(frozen=True)
class _Pending:
    actor: object
    body: BindingPreviewRequest
    binding: KeeneticBinding
    telemetry: Telemetry
    fingerprint: tuple
    created: float


class KeeneticResourceAdapter:
    def __init__(self, db, auth, settings, key, resources, services):
        self.db, self.auth, self.settings = db, auth, settings
        self.resources, self.services = resources, services
        self._key, self._cipher = key, AESGCM(key)
        self._lock = threading.RLock()
        self._previews = {}
        self._cache = OrderedDict()
        self._clock, self._last_clock = time.monotonic, None
        self._closed = False
        self._slots = threading.BoundedSemaphore(4)
        self._reader = read_telemetry

    def _now(self):
        now = self._clock()
        if type(now) not in (int, float) or not math.isfinite(now):
            raise ApiError("server_unavailable", 503)
        if self._last_clock is not None and now < self._last_clock:
            self._previews.clear(); self._cache.clear()
        self._last_clock = now
        for key, pending in list(self._previews.items()):
            if now - pending.created >= PREVIEW_TTL:
                del self._previews[key]
        for key, cached in list(self._cache.items()):
            if now - cached[0] >= CACHE_TTL:
                del self._cache[key]
        return now

    def close(self):
        with self._lock:
            self._previews.clear(); self._cache.clear(); self._closed = True

    @staticmethod
    def _aad(row):
        return f"larenor-keenetic-binding-v1:{row['resource_id']}:{row['binding_id']}:{row['revision']}".encode()

    def _decode(self, row):
        value = KeeneticBinding.model_validate_json(
            self._cipher.decrypt(row["nonce"], row["ciphertext"], self._aad(row)))
        if (value.id != row["binding_id"] or value.revision != row["revision"] or
                value.ref.id != row["resource_id"] or value.ref.kind != "resource" or
                (value.ref.coreId, value.ref.homeId) !=
                (self.resources.scope.coreId, self.resources.scope.homeId)):
            raise ValueError()
        return value

    def validate_storage(self):
        try:
            with self.db.connection() as c:
                c.execute("BEGIN")
                for row in schema.validate(c, self._key, self.resources.scope):
                    self._decode(row)
        except (ValueError, TypeError, InvalidTag, ValidationError):
            raise StartupError("keenetic_resource_storage_invalid") from None

    @contextmanager
    def _tx(self, actor, core, home, *, admin=False):
        try:
            with self._lock, self.resources._transaction(actor, core, home, admin=admin) as (c, facts):
                if self._closed:
                    raise ApiError("server_unavailable", 503)
                self._now(); schema.validate(c, self._key, self.resources.scope)
                yield c, facts
        except ApiError:
            with self._lock:
                self._cache.clear()
            raise

    def _target(self, c, facts, resource):
        row, ref, data = self.resources._target(c, resource)
        self.resources._require(facts, row, ref, data)
        if ref.kind != "resource":
            raise ApiError("not_found", 404)
        saved = c.execute("SELECT * FROM keenetic_resource_bindings WHERE resource_id=?", (resource,)).fetchone()
        return row, ref, data, None if saved is None else self._decode(saved)

    def _facts(self, c, facts, resource, body=None):
        row, ref, data, binding = self._target(c, facts, resource)
        if body is not None:
            self.resources._require(facts, row, ref, data,
                expected_revision=body.expectedResourceRevision,
                expected_acl_revision=body.expectedAclRevision)
            if (None if binding is None else binding.id) != body.expectedBindingId:
                raise ApiError("keenetic_binding_changed", 409)
            service_id, revision = body.serviceId, body.expectedServiceRevision
        else:
            if binding is None:
                raise ApiError("not_found", 404)
            service_id, revision = binding.serviceId, binding.serviceRevision
        try:
            service = self.services._keenetic_connection(c, service_id, revision)
        except ApiError as error:
            if error.code in ("not_found", "revision_conflict", "keenetic_service_unverified"):
                raise ApiError("keenetic_binding_changed", 409) from None
            raise
        service_digest = hmac.new(self._key, json.dumps([
            service.id, service.revision, service.base_url, service.name, dict(service.credentials)
        ], sort_keys=True).encode(), hashlib.sha256).digest()
        fingerprint = (facts.model_dump_json(), ref.model_dump_json(), row["revision"],
                       row["acl_revision"], None if binding is None else binding.model_dump_json(), service_digest)
        return fingerprint, row, ref, data, binding, service

    def _fresh(self, actor, core, home, resource, fingerprint, body, cancelled, *, admin=False):
        if cancelled():
            raise ApiError("request_timeout", 408)
        with self._tx(actor, core, home, admin=admin) as (c, facts):
            if self._facts(c, facts, resource, body)[0] != fingerprint:
                raise ApiError("keenetic_binding_changed", 409)
        if cancelled():
            raise ApiError("request_timeout", 408)

    def _observe(self, actor, core, home, resource, fingerprint, service, body, cancelled, *, admin=False):
        if not self._slots.acquire(blocking=False):
            raise ApiError("keenetic_limit_reached", 429)
        try:
            def guard():
                self._fresh(actor, core, home, resource, fingerprint, body, cancelled, admin=admin)
            try:
                value = self._reader(service, guard)
                guard()
                return Telemetry.model_validate(value)
            except ValidationError:
                raise ApiError("keenetic_snapshot_unsupported", 502) from None
            except ApiError as error:
                allowed = {"request_timeout", "invalid_session", "not_found", "forbidden",
                           "keenetic_binding_changed", "keenetic_limit_reached",
                           "keenetic_upstream_unavailable", "keenetic_upstream_unauthorized",
                           "keenetic_upstream_denied", "keenetic_upstream_unsupported"}
                if error.code not in allowed:
                    raise ApiError("keenetic_upstream_unavailable", 502) from None
                raise
            except Exception:  # noqa: BLE001 - the packaged seam must fail closed.
                raise ApiError("keenetic_upstream_unavailable", 502) from None
        finally:
            self._slots.release()

    def retire_invalid_session(self, access):
        try:
            digest = token_hash(access)
        except (UnicodeError, AttributeError):
            return
        with self._lock, self.db.connection() as c:
            row = c.execute("SELECT family_id FROM session_tokens WHERE access_hash=?", (digest,)).fetchone()
            if row is not None:
                for key in list(self._cache):
                    if key[-1] == row["family_id"]:
                        del self._cache[key]

    def preview(self, actor, core, home, resource, body, *, cancelled=lambda: False):
        body = BindingPreviewRequest.model_validate(body)
        started = self._now()
        caller_cancelled = cancelled
        cancelled = lambda: caller_cancelled() or self._clock() - started >= OPERATION_TTL
        with self._tx(actor, core, home, admin=True) as (c, facts):
            if len(self._previews) >= MAX_PREVIEWS or sum(p.actor.id == actor.id for p in self._previews.values()) >= MAX_ACTOR_PREVIEWS:
                raise ApiError("keenetic_limit_reached", 429)
            fingerprint, _row, ref, _data, old, service = self._facts(c, facts, resource, body)
            proposed = KeeneticBinding(id=uuid.uuid4().hex,
                revision=1 if old is None else self.resources._next(old.revision), ref=ref,
                serviceId=service.id, serviceRevision=service.revision)
        telemetry = self._observe(actor, core, home, resource, fingerprint, service, body, cancelled, admin=True)
        with self._tx(actor, core, home, admin=True) as (c, facts):
            if self._facts(c, facts, resource, body)[0] != fingerprint or cancelled():
                raise ApiError("keenetic_binding_changed", 409)
            if len(self._previews) >= MAX_PREVIEWS or sum(p.actor.id == actor.id for p in self._previews.values()) >= MAX_ACTOR_PREVIEWS:
                raise ApiError("keenetic_limit_reached", 429)
            identity = uuid.uuid4().hex
            self._previews[identity] = _Pending(actor, body, proposed, telemetry, fingerprint, self._now())
            return {"preview": {"id": identity, "expiresInMs": 60000,
                    "binding": proposed.model_dump(), "snapshot": telemetry.model_dump()}}

    def _pending(self, actor, resource, preview_id):
        pending = self._previews.get(preview_id)
        if pending is None or pending.actor != actor or pending.binding.ref.id != resource:
            raise ApiError("keenetic_preview_invalid", 409)
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
                raise ApiError("keenetic_binding_changed", 409)
            binding = pending.binding
            if pending.body.expectedBindingId is None and len(schema.rows(c)) >= schema.MAX_BINDINGS:
                raise ApiError("keenetic_limit_reached", 429)
            plain = binding.model_dump_json().encode(); nonce = secrets.token_bytes(12)
            row = {"resource_id": resource, "binding_id": binding.id, "revision": binding.revision}
            cipher = self._cipher.encrypt(nonce, plain, self._aad(row))
            c.execute("INSERT INTO keenetic_resource_bindings VALUES(?,?,?,?,?) ON CONFLICT(resource_id) DO UPDATE SET "
                      "binding_id=excluded.binding_id,revision=excluded.revision,nonce=excluded.nonce,ciphertext=excluded.ciphertext",
                      (resource, binding.id, binding.revision, nonce, cipher))
            schema.update(c, self._key, self.resources.scope); schema.validate(c, self._key, self.resources.scope)
            self._cache.clear()
            return {"binding": binding.model_dump()}

    def snapshot(self, actor, core, home, resource, *, cancelled=lambda: False):
        started = self._now()
        caller_cancelled = cancelled
        cancelled = lambda: caller_cancelled() or self._clock() - started >= OPERATION_TTL
        with self._tx(actor, core, home) as (c, facts):
            fingerprint, row, ref, _data, binding, service = self._facts(c, facts, resource)
            # The exact required tuple is the prefix; current user/session facts prevent detached reuse.
            key = (core, home, resource, binding.id, binding.revision, service.id, service.revision,
                   actor.id, facts.revision, actor.token_id, actor.family_id)
            now = self._now(); cached = self._cache.get(key)
            if cached is not None and cached[1] == fingerprint and not cancelled():
                return {"snapshot": {**cached[2], "remainingTtlMs": max(0, int(
                    (CACHE_TTL - (now - cached[0])) * 1000))}}
        telemetry = self._observe(actor, core, home, resource, fingerprint, service, None, cancelled)
        with self._tx(actor, core, home) as (c, facts):
            current, row, ref, _data, binding, service = self._facts(c, facts, resource)
            if current != fingerprint or cancelled():
                raise ApiError("keenetic_binding_changed", 409)
            result = ResourceSnapshot(ref=ref, bindingId=binding.id, bindingRevision=binding.revision,
                serviceId=service.id, serviceRevision=service.revision, resourceRevision=row["revision"],
                aclRevision=row["acl_revision"], observedAt=utc(self.settings.clock()),
                remainingTtlMs=5000, telemetry=telemetry).model_dump()
            if len(json.dumps(result).encode()) > MAX_CACHE_ENTRY:
                raise ApiError("keenetic_snapshot_unsupported", 502)
            self._cache.pop(key, None)
            while sum(k[7] == actor.id for k in self._cache) >= MAX_USER_CACHE:
                del self._cache[next(k for k in self._cache if k[7] == actor.id)]
            while len(self._cache) >= MAX_CACHE:
                self._cache.popitem(last=False)
            self._cache[key] = (self._now(), fingerprint, result)
            return {"snapshot": result}
