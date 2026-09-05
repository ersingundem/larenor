"""Durable read-only work, with fresh authority checks around every inspection.

A local process lock covers backend work; SQLite transactions cover only durable
state changes. A crash can repeat inspection, but this module cannot install or
mutate host services. The stored plan remains an immutable disabled catalog plan.
"""

from contextlib import contextmanager
import fcntl
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
from .catalog import load_catalog, verify_plan
from .job_models import CancelJobRequest, CreateJobRequest, JobEvent, JobPayload, PluginJob
from .preflight_models import PreflightResult


MAX_JOBS = 10000
MAX_QUEUED = 16
MAX_EVENTS = 10000
MAX_CIPHERTEXT = 65536
JOB_BINDING = ("id", "sequence", "revision", "actor_id", "actor_revision", "family_id", "request_id",
               "preview_id", "state", "phase", "cancel_requested", "error_code", "created_at", "updated_at")
EVENT_BINDING = ("sequence", "job_id", "job_revision", "code", "created_at")


def _identifier(value):
    if type(value) is not str or not re.fullmatch(r"[0-9a-f]{32}", value):
        raise ApiError("invalid_request")


def _paging(limit, cursor, *, zero=False):
    if type(limit) is not int or not 1 <= limit <= 100:
        raise ApiError("invalid_request")
    if cursor is not None and (type(cursor) is not int or not (0 if zero else 1) <= cursor <= 2**63 - 1):
        raise ApiError("invalid_request")


class JobManagement:
    def __init__(self, db, auth, settings, key, previews, backend=None):
        self.db, self.auth, self.settings, self.previews, self.backend = db, auth, settings, previews, backend
        self._cipher = AESGCM(key)

    def _assert_admin(self, connection, actor):
        return self.previews._assert_admin(connection, actor)

    @staticmethod
    def _aad(row):
        return b"larenor:plugins:jobs:schema=1:job:" + json.dumps(
            {key: row[key] for key in JOB_BINDING}, sort_keys=True, separators=(",", ":")).encode("ascii")

    @staticmethod
    def _event_aad(row):
        return b"larenor:plugins:jobs:schema=1:event:" + json.dumps(
            {key: row[key] for key in EVENT_BINDING}, sort_keys=True, separators=(",", ":")).encode("ascii")

    @staticmethod
    def _public(row, payload):
        return {"id": row["id"], "revision": row["revision"], "operation": "preflight",
                "previewId": row["preview_id"], "requestId": row["request_id"],
                "serviceId": payload.plan.serviceId, "distributionId": payload.plan.distributionId,
                "planHash": payload.plan.planHash, "platform": payload.plan.image.platform,
                "state": row["state"], "phase": row["phase"], "cancelRequested": bool(row["cancel_requested"]),
                "createdAt": utc(row["created_at"]), "updatedAt": utc(row["updated_at"]),
                "result": payload.result, "errorCode": row["error_code"]}

    def _decode(self, row):
        try:
            for key in ("id", "actor_id", "family_id", "request_id", "preview_id"):
                if type(row[key]) is not str or not re.fullmatch(r"[0-9a-f]{32}", row[key]):
                    raise ValueError()
            for key in ("sequence", "revision", "actor_revision"):
                if type(row[key]) is not int or not 1 <= row[key] <= 2**63 - 2:
                    raise ValueError()
            if (row["cancel_requested"] not in (0, 1) or len(row["nonce"]) != 12 or
                    len(row["ciphertext"]) > MAX_CIPHERTEXT or
                    any(type(row[key]) is not int or not 0 <= row[key] <= 253402300799 for key in ("created_at", "updated_at"))):
                raise ValueError()
            raw = self._cipher.decrypt(row["nonce"], row["ciphertext"], self._aad(row))
            payload = JobPayload.model_validate_json(raw)
            if (payload.request.previewId != row["preview_id"] or payload.request.requestId != row["request_id"] or
                    payload.request.planHash != payload.plan.planHash or payload.request.expectedRevision != 1 or
                    payload.result is not None and payload.result.catalogDigest != payload.plan.catalogDigest):
                raise ValueError()
            PluginJob.model_validate(self._public(row, payload))
            return payload
        except (InvalidTag, ValueError, TypeError, OverflowError):
            raise ApiError("plugin_job_storage_unavailable", 503) from None

    def _decode_event(self, row):
        try:
            if len(row["nonce"]) != 12 or len(row["ciphertext"]) != 21:
                raise ValueError()
            if self._cipher.decrypt(row["nonce"], row["ciphertext"], self._event_aad(row)) != b"event":
                raise ValueError()
            return JobEvent(sequence=row["sequence"], code=row["code"], createdAt=utc(row["created_at"]),
                            jobRevision=row["job_revision"]).model_dump()
        except (InvalidTag, ValueError, TypeError, OverflowError):
            raise ApiError("plugin_job_storage_unavailable", 503) from None

    def _save(self, connection, row, payload):
        # Encoding through strict models also rejects unsafe model_copy results.
        PluginJob.model_validate(self._public(row, payload))
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(nonce, payload.model_dump_json().encode("utf-8"), self._aad(row))
        if len(ciphertext) > MAX_CIPHERTEXT:
            raise ApiError("plugin_job_storage_unavailable", 503)
        connection.execute("UPDATE plugin_jobs SET " + ",".join(key + "=?" for key in JOB_BINDING) +
                           ",nonce=?,ciphertext=? WHERE id=?", (*[row[key] for key in JOB_BINDING], nonce, ciphertext, row["id"]))

    def _event(self, connection, row, code):
        now = row["updated_at"]
        cursor = connection.execute("INSERT INTO plugin_job_events(job_id,job_revision,code,created_at,nonce,ciphertext) VALUES(?,?,?,?,?,?)",
                                    (row["id"], row["revision"], code, now, b"", b""))
        event = {"sequence": cursor.lastrowid, "job_id": row["id"], "job_revision": row["revision"], "code": code, "created_at": now}
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(nonce, b"event", self._event_aad(event))
        connection.execute("UPDATE plugin_job_events SET nonce=?,ciphertext=? WHERE sequence=?", (nonce, ciphertext, cursor.lastrowid))
        connection.execute("DELETE FROM plugin_job_events WHERE sequence IN (SELECT sequence FROM plugin_job_events "
                           "ORDER BY sequence DESC LIMIT -1 OFFSET ?)", (MAX_EVENTS,))

    def _transition(self, connection, row, payload, *, state, code, error=None, result=None, cancel=False):
        changed = dict(row)
        changed.update(revision=row["revision"] + 1, state=state,
                       phase="checking_requirements" if state == "running" else "complete",
                       cancel_requested=int(cancel), error_code=error,
                       updated_at=max(row["updated_at"], int(self.settings.clock())))
        value = payload.model_copy(update={"result": result})
        self._save(connection, changed, value)
        self._event(connection, changed, code)
        return {"job": self._public(changed, value)}

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                connection.execute("BEGIN")
                for table, maximum, decode in (("plugin_jobs", MAX_JOBS, self._decode),
                                                ("plugin_job_events", MAX_EVENTS, self._decode_event)):
                    rows = connection.execute(f"SELECT * FROM {table} LIMIT ?", (maximum + 1,))
                    # Decode each accepted row before requesting the next one;
                    # retained encrypted history must not accumulate in memory.
                    for count, row in enumerate(rows, start=1):
                        if count > maximum:
                            raise ApiError("plugin_job_storage_unavailable", 503)
                        decode(row)
        except (ApiError, sqlite3.Error):
            raise StartupError("invalid_plugin_jobs_storage") from None

    def capabilities(self, actor):
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            return {"preflightConfigured": self.backend is not None, "installAvailable": False}

    def create(self, actor, body: CreateJobRequest):
        with self.db.transaction() as connection:
            actor_revision = self._assert_admin(connection, actor)
            existing = connection.execute("SELECT * FROM plugin_jobs WHERE actor_id=? AND request_id=?", (actor.id, body.requestId)).fetchone()
            if existing:
                payload = self._decode(existing)
                if payload.request != body:
                    raise ApiError("plugin_job_conflict", 409)
                return {"job": self._public(existing, payload)}
            if self.backend is None:
                raise ApiError("plugin_worker_unavailable", 503)
            if connection.execute("SELECT 1 FROM plugin_jobs WHERE preview_id=?", (body.previewId,)).fetchone():
                raise ApiError("plugin_job_conflict", 409)
            preview = connection.execute("SELECT * FROM plugin_previews WHERE id=?", (body.previewId,)).fetchone()
            if preview is None or preview["actor_id"] != actor.id or preview["family_id"] != actor.family_id:
                raise ApiError("not_found", 404)
            calculated = self.previews._decode(preview)
            if preview["revision"] != body.expectedRevision:
                raise ApiError("revision_conflict", 409)
            if preview["expires_at"] <= self.settings.clock():
                raise ApiError("plugin_preview_expired", 409)
            if (preview["actor_revision"] != actor_revision or calculated.planHash != body.planHash):
                raise ApiError("plugin_catalog_changed", 409)
            try:
                verify_plan(calculated, load_catalog())
            except (ValueError, OSError):
                raise ApiError("plugin_catalog_changed", 409) from None
            if (connection.execute("SELECT COUNT(*) FROM plugin_jobs").fetchone()[0] >= MAX_JOBS or
                    connection.execute("SELECT COUNT(*) FROM plugin_jobs WHERE state='queued'").fetchone()[0] >= MAX_QUEUED):
                raise ApiError("plugin_job_limit_reached", 409)
            now = int(self.settings.clock())
            row = {"id": uuid.uuid4().hex, "sequence": connection.execute("SELECT COALESCE(MAX(sequence),0)+1 FROM plugin_jobs").fetchone()[0],
                   "revision": 1, "actor_id": actor.id, "actor_revision": actor_revision, "family_id": actor.family_id,
                   "request_id": body.requestId, "preview_id": body.previewId, "state": "queued", "phase": "queued",
                   "cancel_requested": 0, "error_code": None, "created_at": now, "updated_at": now}
            connection.execute("INSERT INTO plugin_jobs VALUES(" + ",".join("?" for _ in range(16)) + ")", (*row.values(), b"", b""))
            payload = JobPayload(request=body, plan=calculated)
            self._save(connection, row, payload)
            self._event(connection, row, "job_queued")
            return {"job": self._public(row, payload)}

    def get(self, actor, job_id):
        _identifier(job_id)
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            row = self._find(connection, job_id)
            return {"job": self._public(row, self._decode(row))}

    @staticmethod
    def _find(connection, job_id):
        row = connection.execute("SELECT * FROM plugin_jobs WHERE id=?", (job_id,)).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        return row

    def list(self, actor, *, before=None, limit=25):
        _paging(limit, before)
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            rows = connection.execute("SELECT * FROM plugin_jobs WHERE sequence<? ORDER BY sequence DESC LIMIT ?",
                                      (before if before is not None else 2**63 - 1, limit + 1)).fetchall()
            return {"jobs": [self._public(row, self._decode(row)) for row in rows[:limit]],
                    "nextBefore": rows[limit - 1]["sequence"] if len(rows) > limit else None}

    def events(self, actor, job_id, *, after=0, limit=25):
        _identifier(job_id)
        _paging(limit, after, zero=True)
        if after is None:
            raise ApiError("invalid_request")
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            self._decode(self._find(connection, job_id))
            rows = connection.execute("SELECT * FROM plugin_job_events WHERE job_id=? AND sequence>? ORDER BY sequence LIMIT ?",
                                      (job_id, after, limit + 1)).fetchall()
            return {"events": [self._decode_event(row) for row in rows[:limit]],
                    "nextAfter": rows[limit - 1]["sequence"] if len(rows) > limit else None}

    def cancel(self, actor, job_id, body: CancelJobRequest):
        _identifier(job_id)
        with self.db.transaction() as connection:
            self._assert_admin(connection, actor)
            row = self._find(connection, job_id)
            payload = self._decode(row)
            if row["revision"] != body.expectedRevision:
                raise ApiError("revision_conflict", 409)
            if row["state"] not in ("queued", "running") or row["cancel_requested"]:
                return {"job": self._public(row, payload)}
            return self._transition(connection, row, payload, state="cancelled" if row["state"] == "queued" else "running",
                                    code="job_cancelled" if row["state"] == "queued" else "job_cancel_requested", cancel=True)

    def _dispatch_authorized(self, connection, row):
        current = connection.execute("SELECT u.revision,u.role,u.disabled,u.must_change_password,f.revoked_at,f.expires_at "
                                     "FROM users u JOIN session_families f ON f.user_id=u.id WHERE u.id=? AND f.id=?",
                                     (row["actor_id"], row["family_id"])).fetchone()
        return bool(current and current["revision"] == row["actor_revision"] and current["role"] == "admin"
                    and not current["disabled"] and not current["must_change_password"] and current["revoked_at"] is None
                    and current["expires_at"] > self.settings.clock())

    @contextmanager
    def _dispatch_lock(self):
        descriptor = None
        try:
            descriptor = os.open(self.settings.data_dir / ".plugin-jobs.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
                raise ApiError("plugin_job_storage_unavailable", 503)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                yield False
                return
            yield True
        except OSError:
            raise ApiError("plugin_job_storage_unavailable", 503) from None
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
            row = connection.execute("SELECT * FROM plugin_jobs WHERE state IN ('queued','running') "
                                     "ORDER BY CASE state WHEN 'running' THEN 0 ELSE 1 END,sequence LIMIT 1").fetchone()
            if row is None:
                return None
            payload = self._decode(row)
            if row["cancel_requested"]:
                return self._transition(connection, row, payload, state="cancelled", code="job_cancelled", cancel=True)
            if not self._dispatch_authorized(connection, row):
                return self._transition(connection, row, payload, state="needs_attention", code="job_needs_attention", error="authority_changed")
            try:
                verified = verify_plan(payload.plan, load_catalog())
            except (ValueError, OSError):
                return self._transition(connection, row, payload, state="needs_attention", code="job_needs_attention", error="catalog_changed")
            if self.backend is None:
                return self._transition(connection, row, payload, state="failed", code="job_failed", error="worker_unavailable")
            self._transition(connection, row, payload, state="running", code="job_started" if row["state"] == "queued" else "job_resumed")
            identifier = row["id"]
        # No DB connection or transaction survives while the backend inspects.
        result, failure = None, None
        try:
            observed = self.backend.inspect(verified)
        except Exception:
            failure = "worker_unavailable"
        else:
            try:
                if not isinstance(observed, PreflightResult):
                    raise ValueError()
                result = PreflightResult.model_validate_json(observed.model_dump_json())
                if (result.catalogDigest != verified.catalogDigest or result.planHash != verified.planHash
                        or result.platform != verified.image.platform):
                    raise ValueError()
            except (ValueError, TypeError):
                result, failure = None, "invalid_worker_result"
        with self.db.transaction() as connection:
            row = self._find(connection, identifier)
            payload = self._decode(row)
            if row["cancel_requested"]:
                return self._transition(connection, row, payload, state="cancelled", code="job_cancelled", cancel=True)
            if not self._dispatch_authorized(connection, row):
                return self._transition(connection, row, payload, state="needs_attention", code="job_needs_attention", error="authority_changed")
            if failure:
                return self._transition(connection, row, payload, state="failed", code="job_failed", error=failure)
            return self._transition(connection, row, payload, state="succeeded", code="job_completed", result=result)
