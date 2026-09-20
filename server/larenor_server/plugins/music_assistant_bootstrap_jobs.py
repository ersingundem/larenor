"""Encrypted durable Music Assistant first-run bootstrap intent."""

from contextlib import contextmanager
import fcntl
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
from .music_assistant_bootstrap_job_models import (
    CreateMusicAssistantBootstrapRequest,
    MusicAssistantBootstrapJob,
    PrivateMusicAssistantBootstrapPayload,
)
from .music_assistant_bootstrap_models import PrivateMusicAssistantBootstrap
from .music_assistant_bootstrap_runtime import MusicAssistantBootstrapRuntimeError
from .music_assistant_core_models import AuthenticatedMusicAssistantReadback


TABLE = "media_music_assistant_bootstraps"
MAX_BOOTSTRAPS = 256
MAX_CIPHERTEXT = 4096
_BINDING = (
    "id", "sequence", "revision", "actor_id", "actor_revision", "family_id",
    "request_id", "installation_id", "installation_revision", "state", "phase",
    "error_code", "created_at", "updated_at",
)


def _identifier(value):
    if type(value) is not str or re.fullmatch(r"[0-9a-f]{32}", value) is None:
        raise ApiError("invalid_request")


class MusicAssistantBootstrapManagement:
    def __init__(self, db, auth, settings, key, installations, core, backend=None):
        self.db, self.auth, self.settings = db, auth, settings
        self.installations, self.core, self.backend = installations, core, backend
        self._cipher = AESGCM(key)

    def _assert_admin(self, connection, actor):
        return self.installations._assert_admin(connection, actor)

    @staticmethod
    def _aad(row):
        return b"larenor:media:music-assistant-bootstraps:schema=1:" + json.dumps(
            {key: row[key] for key in _BINDING},
            sort_keys=True,
            separators=(",", ":"),
        ).encode("ascii")

    def _decode(self, row):
        try:
            if (len(row["nonce"]) != 12
                    or not 16 <= len(row["ciphertext"]) <= MAX_CIPHERTEXT
                    or any(type(row[key]) is not int or not 1 <= row[key] <= 2**63 - 2
                           for key in ("sequence", "revision", "actor_revision",
                                       "installation_revision"))
                    or any(type(row[key]) is not str
                           or re.fullmatch(r"[0-9a-f]{32}", row[key]) is None
                           for key in ("id", "actor_id", "family_id", "request_id",
                                       "installation_id"))):
                raise ValueError()
            raw = self._cipher.decrypt(row["nonce"], row["ciphertext"], self._aad(row))
            payload = PrivateMusicAssistantBootstrapPayload.model_validate_json(raw)
            if payload.private.installationId != row["installation_id"]:
                raise ValueError()
            return payload
        except (InvalidTag, ValidationError, ValueError, TypeError, AttributeError):
            raise ApiError("music_assistant_bootstrap_storage_unavailable", 503) from None

    @staticmethod
    def _public(row):
        try:
            return MusicAssistantBootstrapJob.model_validate({
                "id": row["id"],
                "requestId": row["request_id"],
                "installationId": row["installation_id"],
                "serviceId": "music_assistant",
                "revision": row["revision"],
                "state": row["state"],
                "phase": row["phase"],
                "errorCode": row["error_code"],
                "installAvailable": False,
                "createdAt": utc(row["created_at"]),
                "updatedAt": utc(row["updated_at"]),
            }).model_dump()
        except (ValidationError, ValueError, TypeError, AttributeError):
            raise ApiError("music_assistant_bootstrap_storage_unavailable", 503) from None

    def _installation(self, connection, row):
        installation = connection.execute(
            "SELECT * FROM media_installations WHERE id=?", (row["installation_id"],)
        ).fetchone()
        if installation is None or installation["revision"] != row["installation_revision"]:
            raise ValueError()
        payload = self.installations._decode(installation)
        if (installation["state"] != "container_started"
                or installation["phase"] != "complete"
                or payload.request.serviceId != "music_assistant"):
            raise ValueError()
        return installation

    def _validate_row(self, connection, row):
        payload = self._decode(row)
        self._public(row)
        try:
            self._installation(connection, row)
        except (ApiError, ValueError, TypeError, AttributeError):
            raise ApiError("music_assistant_bootstrap_storage_unavailable", 503) from None
        state, phase, error = row["state"], row["phase"], row["error_code"]
        if ((state == "queued" and (phase != "queued" or error is not None or row["revision"] != 1))
                or (state == "running" and (phase != "bootstrapping" or error is not None))
                or (state == "succeeded" and (phase != "complete" or error is not None))
                or (state in {"needs_attention", "failed"}
                    and (phase != "complete" or error is None))):
            raise ApiError("music_assistant_bootstrap_storage_unavailable", 503)
        return payload

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    f"SELECT * FROM {TABLE} LIMIT ?", (MAX_BOOTSTRAPS + 1,)
                ).fetchall()
                if len(rows) > MAX_BOOTSTRAPS:
                    raise ValueError()
                for row in rows:
                    self._validate_row(connection, row)
        except (ApiError, ValueError, sqlite3.Error):
            raise StartupError("invalid_music_assistant_bootstraps_storage") from None

    def create(self, actor, body):
        try:
            body = CreateMusicAssistantBootstrapRequest.model_validate(body)
        except (ValidationError, ValueError, TypeError, AttributeError):
            raise ApiError("invalid_request") from None
        with self.db.transaction() as connection:
            actor_revision = self._assert_admin(connection, actor)
            previous = connection.execute(
                f"SELECT * FROM {TABLE} WHERE actor_id=? AND request_id=?",
                (actor.id, body.requestId),
            ).fetchone()
            if previous is not None:
                if (previous["installation_id"] != body.installationId
                        or previous["installation_revision"] != body.expectedInstallationRevision):
                    raise ApiError("music_assistant_bootstrap_conflict", 409)
                self._validate_row(connection, previous)
                return {"bootstrap": self._public(previous)}
            source = {
                "installation_id": body.installationId,
                "installation_revision": body.expectedInstallationRevision,
            }
            try:
                installation = self._installation(connection, source)
                if (installation["actor_id"] != actor.id
                        or installation["actor_revision"] != actor_revision
                        or installation["family_id"] != actor.family_id):
                    raise ValueError()
            except (ApiError, ValueError, TypeError, AttributeError):
                raise ApiError("music_assistant_installation_changed", 409) from None
            if connection.execute(
                    f"SELECT 1 FROM {TABLE} WHERE installation_id=?",
                    (body.installationId,)).fetchone() is not None:
                raise ApiError("music_assistant_bootstrap_conflict", 409)
            if connection.execute(f"SELECT COUNT(*) FROM {TABLE}").fetchone()[0] >= MAX_BOOTSTRAPS:
                raise ApiError("music_assistant_bootstrap_limit_reached", 409)
            now = int(self.settings.clock())
            row = {
                "id": uuid.uuid4().hex,
                "sequence": connection.execute(
                    f"SELECT COALESCE(MAX(sequence),0)+1 FROM {TABLE}").fetchone()[0],
                "revision": 1,
                "actor_id": actor.id,
                "actor_revision": actor_revision,
                "family_id": actor.family_id,
                "request_id": body.requestId,
                "installation_id": body.installationId,
                "installation_revision": body.expectedInstallationRevision,
                "state": "queued",
                "phase": "queued",
                "error_code": None,
                "created_at": now,
                "updated_at": now,
            }
            payload = PrivateMusicAssistantBootstrapPayload(private=PrivateMusicAssistantBootstrap(
                installationId=body.installationId,
                credential=secrets.token_urlsafe(48),
            ))
            nonce = secrets.token_bytes(12)
            ciphertext = self._cipher.encrypt(
                nonce, payload.model_dump_json().encode("utf-8"), self._aad(row))
            connection.execute(
                f"INSERT INTO {TABLE}(" + ",".join(_BINDING)
                + ",nonce,ciphertext) VALUES(" + ",".join("?" for _ in range(16)) + ")",
                (*[row[key] for key in _BINDING], nonce, ciphertext),
            )
            stored = connection.execute(f"SELECT * FROM {TABLE} WHERE id=?", (row["id"],)).fetchone()
            self._validate_row(connection, stored)
            return {"bootstrap": self._public(stored)}

    def _find(self, connection, identifier):
        row = connection.execute(f"SELECT * FROM {TABLE} WHERE id=?", (identifier,)).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        self._validate_row(connection, row)
        return row

    def get(self, actor, identifier):
        _identifier(identifier)
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            return {"bootstrap": self._public(self._find(connection, identifier))}

    def list(self, actor, *, before=None, limit=10):
        if (type(limit) is not int or not 1 <= limit <= 10
                or before is not None and (type(before) is not int or not 1 <= before <= 2**63 - 1)):
            raise ApiError("invalid_request")
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            rows = connection.execute(
                f"SELECT * FROM {TABLE} WHERE sequence<? ORDER BY sequence DESC LIMIT ?",
                (before or 2**63 - 1, limit + 1),
            ).fetchall()
            for row in rows:
                self._validate_row(connection, row)
            return {
                "bootstraps": [self._public(row) for row in rows[:limit]],
                "nextBefore": rows[limit - 1]["sequence"] if len(rows) > limit else None,
            }

    def private_payload(self, identifier):
        _identifier(identifier)
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            return self._decode(self._find(connection, identifier)).private

    def _save(self, connection, row, payload):
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(
            nonce, payload.model_dump_json().encode("utf-8"), self._aad(row))
        if len(ciphertext) > MAX_CIPHERTEXT:
            raise ApiError("music_assistant_bootstrap_storage_unavailable", 503)
        connection.execute(
            f"UPDATE {TABLE} SET " + ",".join(key + "=?" for key in _BINDING)
            + ",nonce=?,ciphertext=? WHERE id=?",
            (*[row[key] for key in _BINDING], nonce, ciphertext, row["id"]),
        )

    def _transition(self, connection, row, payload, *, state, error=None):
        changed = dict(row)
        changed.update(
            revision=row["revision"] + 1,
            state=state,
            phase="bootstrapping" if state == "running" else "complete",
            error_code=error,
            updated_at=max(row["updated_at"], int(self.settings.clock())),
        )
        self._save(connection, changed, payload)
        return {"bootstrap": self._public(changed)}

    def _gate_locked(self, connection, row):
        current = connection.execute(
            "SELECT u.revision,u.role,u.disabled,u.must_change_password,"
            "f.revoked_at,f.expires_at FROM users u JOIN session_families f "
            "ON f.user_id=u.id WHERE u.id=? AND f.id=?",
            (row["actor_id"], row["family_id"]),
        ).fetchone()
        if not (current and current["revision"] == row["actor_revision"]
                and current["role"] == "admin" and not current["disabled"]
                and not current["must_change_password"] and current["revoked_at"] is None
                and current["expires_at"] > self.settings.clock()):
            return False
        try:
            self._installation(connection, row)
            return True
        except (ApiError, ValueError, TypeError, AttributeError):
            return False

    def _gate(self, identifier):
        try:
            with self.db.connection() as connection:
                connection.execute("BEGIN")
                row = self._find(connection, identifier)
                return row["state"] == "running" and self._gate_locked(connection, row)
        except (ApiError, ValueError, TypeError, AttributeError, OSError):
            return False

    @contextmanager
    def _dispatch_lock(self):
        descriptor = None
        try:
            descriptor = os.open(
                self.settings.data_dir / ".media-music-assistant-bootstraps.lock",
                os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
                0o600,
            )
            info = os.fstat(descriptor)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                raise ApiError("music_assistant_bootstrap_storage_unavailable", 503)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                yield False
                return
            yield True
        except OSError:
            raise ApiError("music_assistant_bootstrap_storage_unavailable", 503) from None
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def tick(self):
        with self._dispatch_lock() as acquired:
            if not acquired:
                return None
            with self.db.transaction() as connection:
                row = connection.execute(
                    f"SELECT * FROM {TABLE} WHERE state IN ('queued','running') "
                    "ORDER BY CASE state WHEN 'running' THEN 0 ELSE 1 END,sequence LIMIT 1"
                ).fetchone()
                if row is None:
                    return None
                payload = self._decode(row)
                if row["state"] == "running":
                    return self._transition(connection, row, payload,
                                            state="needs_attention",
                                            error="music_assistant_bootstrap_interrupted")
                if not self._gate_locked(connection, row):
                    return self._transition(connection, row, payload,
                                            state="needs_attention",
                                            error="music_assistant_bootstrap_authority_changed")
                if self.backend is None:
                    return self._transition(connection, row, payload, state="failed",
                                            error="music_assistant_bootstrap_worker_unavailable")
                self._transition(connection, row, payload, state="running")
                identifier = row["id"]
            try:
                result = self.backend.bootstrap_music_assistant(
                    payload.private,
                    deadline=time.monotonic() + 60.0,
                    gate=lambda: self._gate(identifier),
                )
                if type(result) is not AuthenticatedMusicAssistantReadback:
                    raise MusicAssistantBootstrapRuntimeError(
                        "music_assistant_bootstrap_uncertain", uncertain_effect=True)
            except MusicAssistantBootstrapRuntimeError as failure:
                code = ("invalid_music_assistant_bootstrap_result"
                        if failure.code == "invalid_music_assistant_bootstrap" else failure.code)
                state = "needs_attention" if failure.uncertain_effect or code in {
                    "music_assistant_bootstrap_cancelled",
                    "music_assistant_bootstrap_state_conflict",
                    "music_assistant_bootstrap_readback_changed",
                    "music_assistant_bootstrap_uncertain",
                } else "failed"
                with self.db.transaction() as connection:
                    row = self._find(connection, identifier)
                    return self._transition(connection, row, self._decode(row),
                                            state=state, error=code)
            except Exception:
                with self.db.transaction() as connection:
                    row = self._find(connection, identifier)
                    return self._transition(
                        connection, row, self._decode(row), state="needs_attention",
                        error="invalid_music_assistant_bootstrap_result")

            if not self._gate(identifier):
                with self.db.transaction() as connection:
                    row = self._find(connection, identifier)
                    return self._transition(connection, row, self._decode(row),
                                            state="needs_attention",
                                            error="music_assistant_bootstrap_authority_changed")
            try:
                self.core.record_authenticated_readback(
                    payload.private.installationId,
                    row["installation_revision"],
                    result,
                )
            except ApiError:
                with self.db.transaction() as connection:
                    row = self._find(connection, identifier)
                    return self._transition(connection, row, self._decode(row),
                                            state="needs_attention",
                                            error="music_assistant_bootstrap_readback_rejected")
            with self.db.transaction() as connection:
                row = self._find(connection, identifier)
                if not self._gate_locked(connection, row):
                    return self._transition(connection, row, self._decode(row),
                                            state="needs_attention",
                                            error="music_assistant_bootstrap_authority_changed")
                return self._transition(connection, row, self._decode(row), state="succeeded")
