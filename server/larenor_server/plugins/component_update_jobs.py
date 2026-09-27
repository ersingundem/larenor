"""Authenticated durable lifecycle for verified component update effects."""

import fcntl
import hashlib
import hmac
import json
import math
import os
import sqlite3
import stat
import time

from ..errors import ApiError, StartupError
from .component_updates import (
    CancelComponentUpdateJobRequest,
    ComponentUpdateCommand,
    ComponentUpdateEffectResult,
    ComponentUpdateError,
    ComponentUpdateJob,
    ComponentUpdateJobs,
    verify_update_command,
)


MAX_JOBS = 1024
TABLE = """CREATE TABLE component_update_jobs (
    update_id TEXT PRIMARY KEY CHECK(length(update_id)=32),
    sequence INTEGER NOT NULL UNIQUE CHECK(sequence>0),
    revision INTEGER NOT NULL CHECK(revision>0),
    actor_id TEXT NOT NULL CHECK(length(actor_id)=32),
    actor_revision INTEGER NOT NULL CHECK(actor_revision>0),
    family_id TEXT NOT NULL CHECK(length(family_id)=32),
    installation_id TEXT NOT NULL CHECK(length(installation_id)=32),
    service_id TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('queued','validating','ready','running',
        'succeeded','failed','cancelled','needs_attention')),
    cancel_requested INTEGER NOT NULL CHECK(cancel_requested IN (0,1)),
    error_code TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    command_json TEXT NOT NULL,
    authentication_tag TEXT NOT NULL)"""
INDEX = """CREATE INDEX component_update_jobs_dispatch
    ON component_update_jobs(state,sequence)"""


def migrate_component_update_jobs(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='component_update_jobs_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name IN ('component_update_jobs','component_update_jobs_dispatch') "
            "OR tbl_name='component_update_jobs'"
        ).fetchall()
        actual = {
            row["name"]: row
            for row in rows
            if not (row["type"] == "index" and row["sql"] is None)
        }
        implicit = [
            row for row in rows if row["type"] == "index" and row["sql"] is None
        ]
        if marker is None:
            if actual or implicit:
                raise ValueError("unmarked_component_update_jobs")
            connection.execute(TABLE)
            connection.execute(INDEX)
            connection.execute(
                "INSERT INTO metadata VALUES('component_update_jobs_schema','1')"
            )
            return
        if (
            marker["value"] != "1"
            or set(actual)
            != {"component_update_jobs", "component_update_jobs_dispatch"}
            or " ".join(actual["component_update_jobs"]["sql"].split())
            != " ".join(TABLE.split())
            or " ".join(
                actual["component_update_jobs_dispatch"]["sql"].split()
            )
            != " ".join(INDEX.split())
            or len(implicit) != 2
        ):
            raise ValueError("invalid_component_update_jobs")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("component_update_jobs_storage_invalid") from None


class ComponentUpdateJobStore:
    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings, self._key = db, auth, settings, key
        self.context = context
        self.backend = None

    def bind_backend(self, backend):
        if (
            not callable(getattr(backend, "validate_update", None))
            or not callable(getattr(backend, "execute_update", None))
        ):
            raise StartupError("component_update_worker_invalid")
        if self.backend is not None:
            raise StartupError("component_update_worker_invalid")
        self.backend = backend

    def _admin(self, connection, actor):
        self.auth.assert_current(connection, actor)
        if actor.role != "admin" or actor.must_change_password:
            raise ApiError("forbidden", 403)
        row = connection.execute(
            "SELECT revision FROM users WHERE id=?", (actor.id,)
        ).fetchone()
        if row is None or type(row["revision"]) is not int:
            raise ApiError("forbidden", 403)
        return row["revision"]

    def _tag(self, row):
        payload = json.dumps(
            [
                self.context.coreId,
                self.context.homeId,
                *(
                    row[key]
                    for key in (
                        "update_id",
                        "sequence",
                        "revision",
                        "actor_id",
                        "actor_revision",
                        "family_id",
                        "installation_id",
                        "service_id",
                        "state",
                        "cancel_requested",
                        "error_code",
                        "created_at",
                        "updated_at",
                        "command_json",
                    )
                ),
            ],
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("ascii")
        return hmac.new(
            self._key,
            b"larenor-component-update-job-v1\0" + payload,
            hashlib.sha256,
        ).hexdigest()

    def _decode(self, row):
        try:
            if (
                type(row["sequence"]) is not int
                or not 1 <= row["sequence"] <= 2**63 - 1
                or type(row["revision"]) is not int
                or not 1 <= row["revision"] <= 2**63 - 1
                or type(row["actor_revision"]) is not int
                or row["actor_revision"] < 1
                or any(
                    type(row[key]) is not str or len(row[key]) != 32
                    for key in (
                        "update_id",
                        "actor_id",
                        "family_id",
                        "installation_id",
                    )
                )
                or type(row["service_id"]) is not str
                or row["cancel_requested"] not in (0, 1)
                or type(row["created_at"]) is not float
                or type(row["updated_at"]) is not float
                or not math.isfinite(row["created_at"])
                or not math.isfinite(row["updated_at"])
                or row["updated_at"] < row["created_at"]
                or type(row["command_json"]) is not str
                or len(row["command_json"].encode("utf-8")) > 131072
                or type(row["authentication_tag"]) is not str
                or not hmac.compare_digest(
                    row["authentication_tag"], self._tag(row)
                )
            ):
                raise ValueError("invalid_component_update_job")
            command = verify_update_command(
                ComponentUpdateCommand.model_validate_json(row["command_json"])
            )
            if (
                command.updateId != row["update_id"]
                or command.installationId != row["installation_id"]
                or command.serviceId != row["service_id"]
            ):
                raise ValueError("component_update_job_command_mismatch")
            return command
        except (
            ComponentUpdateError,
            ValueError,
            TypeError,
            AttributeError,
            RecursionError,
        ):
            raise ApiError("component_update_job_storage_unavailable", 503) from None

    def _public(self, row, command):
        return ComponentUpdateJob(
            schemaVersion=1,
            updateId=command.updateId,
            installationId=command.installationId,
            serviceId=command.serviceId,
            revision=row["revision"],
            state=row["state"],
            cancelRequested=bool(row["cancel_requested"]),
            errorCode=row["error_code"],
            sourceDigest=command.sourceDigest,
            reviewDigest=command.reviewDigest,
            targetManifestDigest=command.targetManifestDigest,
            commandDigest=command.commandDigest,
            createdAtMs=int(row["created_at"] * 1000),
            updatedAtMs=int(row["updated_at"] * 1000),
        )

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM component_update_jobs ORDER BY sequence LIMIT ?",
                    (MAX_JOBS + 1,),
                ).fetchall()
                if len(rows) > MAX_JOBS:
                    raise ValueError("component_update_job_limit")
                for row in rows:
                    self._public(row, self._decode(row))
        except (ApiError, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise StartupError("component_update_jobs_storage_invalid") from None

    def enqueue(self, actor, command):
        self.auth.rate_limit([("component_update_enqueue", actor.id, 12)])
        command = verify_update_command(command)
        now = float(self.settings.clock())
        if not math.isfinite(now) or not 0 <= now <= (2**63 - 1) / 1000:
            raise ApiError("component_update_unavailable", 503)
        try:
            with self.db.transaction() as connection:
                actor_revision = self._admin(connection, actor)
                if connection.execute(
                    "SELECT count(*) FROM component_update_jobs"
                ).fetchone()[0] >= MAX_JOBS:
                    raise ApiError("component_update_job_limit", 429)
                if connection.execute(
                    "SELECT 1 FROM component_update_jobs WHERE update_id=?",
                    (command.updateId,),
                ).fetchone():
                    raise ApiError("component_update_job_conflict", 409)
                sequence = connection.execute(
                    "SELECT COALESCE(MAX(sequence),0)+1 FROM component_update_jobs"
                ).fetchone()[0]
                row = {
                    "update_id": command.updateId,
                    "sequence": sequence,
                    "revision": 1,
                    "actor_id": actor.id,
                    "actor_revision": actor_revision,
                    "family_id": actor.family_id,
                    "installation_id": command.installationId,
                    "service_id": command.serviceId,
                    "state": "queued",
                    "cancel_requested": 0,
                    "error_code": None,
                    "created_at": now,
                    "updated_at": now,
                    "command_json": command.model_dump_json(),
                }
                row["authentication_tag"] = self._tag(row)
                connection.execute(
                    "INSERT INTO component_update_jobs VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    tuple(row.values()),
                )
            return self._public(row, command)
        except ApiError:
            raise
        except (ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("component_update_unavailable", 503) from None

    @staticmethod
    def _find(connection, update_id):
        row = connection.execute(
            "SELECT * FROM component_update_jobs WHERE update_id=?", (update_id,)
        ).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        return row

    def get(self, actor, update_id):
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._admin(connection, actor)
            row = self._find(connection, update_id)
            return self._public(row, self._decode(row))

    def latest(self, actor):
        """Return the newest authenticated job for each managed installation."""
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._admin(connection, actor)
            rows = connection.execute(
                "SELECT * FROM component_update_jobs ORDER BY sequence DESC LIMIT ?",
                (MAX_JOBS,),
            ).fetchall()
            selected = []
            installations = set()
            for row in rows:
                command = self._decode(row)
                if command.installationId in installations:
                    continue
                installations.add(command.installationId)
                selected.append(self._public(row, command))
                if len(selected) == 6:
                    break
            return ComponentUpdateJobs(schemaVersion=1, jobs=tuple(selected))

    def cancel(self, actor, update_id, body):
        try:
            body = CancelComponentUpdateJobRequest.model_validate(body)
        except (ValueError, TypeError, AttributeError):
            raise ApiError("invalid_request") from None
        with self.db.transaction() as connection:
            self._admin(connection, actor)
            row = self._find(connection, update_id)
            command = self._decode(row)
            if row["revision"] != body.expectedRevision:
                raise ApiError("revision_conflict", 409)
            if row["state"] in {"succeeded", "failed", "cancelled"}:
                return self._public(row, command)
            changed = dict(row)
            changed.update(
                revision=row["revision"] + 1,
                state=(
                    "cancelled"
                    if row["state"] in {"queued", "ready"}
                    else row["state"]
                ),
                cancel_requested=1,
                updated_at=max(row["updated_at"], float(self.settings.clock())),
            )
            changed["authentication_tag"] = self._tag(changed)
            connection.execute(
                "UPDATE component_update_jobs SET revision=?,state=?,"
                "cancel_requested=?,updated_at=?,authentication_tag=? "
                "WHERE update_id=?",
                (
                    changed["revision"],
                    changed["state"],
                    changed["cancel_requested"],
                    changed["updated_at"],
                    changed["authentication_tag"],
                    update_id,
                ),
            )
            return self._public(changed, command)

    def _transition(self, connection, row, command, *, state, error=None):
        changed = dict(row)
        changed.update(
            revision=row["revision"] + 1,
            state=state,
            error_code=error,
            updated_at=max(row["updated_at"], float(self.settings.clock())),
        )
        changed["authentication_tag"] = self._tag(changed)
        connection.execute(
            "UPDATE component_update_jobs SET revision=?,state=?,error_code=?,"
            "updated_at=?,authentication_tag=? WHERE update_id=?",
            (
                changed["revision"],
                changed["state"],
                changed["error_code"],
                changed["updated_at"],
                changed["authentication_tag"],
                command.updateId,
            ),
        )
        return self._public(changed, command)

    def _dispatch_authorized(self, connection, row):
        current = connection.execute(
            "SELECT u.revision,u.role,u.disabled,u.must_change_password,"
            "f.revoked_at,f.expires_at FROM users u JOIN session_families f "
            "ON f.user_id=u.id WHERE u.id=? AND f.id=?",
            (row["actor_id"], row["family_id"]),
        ).fetchone()
        return bool(
            current
            and current["revision"] == row["actor_revision"]
            and current["role"] == "admin"
            and not current["disabled"]
            and not current["must_change_password"]
            and current["revoked_at"] is None
            and current["expires_at"] > self.settings.clock()
        )

    def _dispatch_lock(self):
        class Lease:
            def __init__(self, owner):
                self.owner = owner
                self.descriptor = None
                self.acquired = False

            def __enter__(self):
                try:
                    self.descriptor = os.open(
                        self.owner.settings.data_dir / ".component-updates.lock",
                        os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
                        0o600,
                    )
                    info = os.fstat(self.descriptor)
                    if (
                        not stat.S_ISREG(info.st_mode)
                        or info.st_uid != os.geteuid()
                        or stat.S_IMODE(info.st_mode) != 0o600
                        or info.st_nlink != 1
                    ):
                        raise OSError()
                    try:
                        fcntl.flock(
                            self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB
                        )
                    except BlockingIOError:
                        return False
                    self.acquired = True
                    return True
                except OSError:
                    raise ApiError(
                        "component_update_job_storage_unavailable", 503
                    ) from None

            def __exit__(self, *_args):
                if self.descriptor is not None:
                    os.close(self.descriptor)

        return Lease(self)

    def tick(self):
        """Advance one command without repeating an uncertain worker effect."""
        with self._dispatch_lock() as acquired:
            if not acquired:
                return None
            with self.db.transaction() as connection:
                row = connection.execute(
                    "SELECT * FROM component_update_jobs "
                    "WHERE state IN ('running','validating','ready','queued') "
                    "ORDER BY CASE state "
                    "WHEN 'running' THEN 0 WHEN 'validating' THEN 1 "
                    "WHEN 'ready' THEN 2 ELSE 3 END,"
                    "sequence LIMIT 1"
                ).fetchone()
                if row is None:
                    return None
                command = self._decode(row)
                if row["state"] == "running":
                    return self._transition(
                        connection,
                        row,
                        command,
                        state="needs_attention",
                        error="worker_response_unknown",
                    )
                if row["state"] == "validating":
                    return self._transition(
                        connection,
                        row,
                        command,
                        state="needs_attention",
                        error="worker_response_unknown",
                    )
                if row["cancel_requested"]:
                    return self._transition(
                        connection, row, command, state="cancelled"
                    )
                if not self._dispatch_authorized(connection, row):
                    return self._transition(
                        connection,
                        row,
                        command,
                        state="needs_attention",
                        error="authority_changed",
                    )
                if int(float(self.settings.clock()) * 1000) >= command.expiresAtMs:
                    return self._transition(
                        connection,
                        row,
                        command,
                        state="failed",
                        error="confirmation_expired",
                    )
                if self.backend is None:
                    return self._transition(
                        connection,
                        row,
                        command,
                        state="failed",
                        error="worker_unavailable",
                    )
                operation = (
                    "execute_update" if row["state"] == "ready" else "validate_update"
                )
                self._transition(
                    connection,
                    row,
                    command,
                    state="running" if operation == "execute_update" else "validating",
                )
                update_id = command.updateId
            try:
                if operation == "validate_update":
                    validated = self.backend.validate_update(
                        command, time.monotonic() + 5
                    )
                    outcome = "ready" if validated == command else "failed"
                    code = None if outcome == "ready" else "worker_result_invalid"
                else:
                    result = ComponentUpdateEffectResult.model_validate_json(
                        self.backend.execute_update(
                            command, time.monotonic() + 300
                        ).model_dump_json()
                    )
                    if (
                        result.updateId != command.updateId
                        or result.installationId != command.installationId
                        or result.serviceId != command.serviceId
                        or result.commandDigest != command.commandDigest
                        or result.sourceDigest != command.sourceDigest
                        or result.targetManifestDigest
                        != command.targetManifestDigest
                    ):
                        raise ValueError("worker_result_invalid")
                    outcome = result.state
                    code = (
                        None
                        if outcome in {"succeeded", "cancelled"}
                        else result.code
                    )
            except BaseException as error:
                if isinstance(error, (KeyboardInterrupt, SystemExit)):
                    raise
                outcome, code = (
                    ("needs_attention", "worker_response_unknown")
                    if operation == "execute_update"
                    else ("failed", "worker_unavailable")
                )
            with self.db.transaction() as connection:
                row = self._find(connection, update_id)
                command = self._decode(row)
                expected_state = (
                    "running" if operation == "execute_update" else "validating"
                )
                if row["state"] != expected_state:
                    return self._public(row, command)
                if operation == "validate_update" and row["cancel_requested"]:
                    return self._transition(
                        connection, row, command, state="cancelled"
                    )
                if operation == "execute_update":
                    if outcome == "cancelled" and not row["cancel_requested"]:
                        outcome, code = "needs_attention", "worker_result_invalid"
                    elif outcome == "succeeded" and row["cancel_requested"]:
                        outcome, code = "needs_attention", "container_state_unknown"
                return self._transition(
                    connection, row, command, state=outcome, error=code
                )
