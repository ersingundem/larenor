import hashlib
import json
import os
import re
import sqlite3
import stat
import time
import uuid
from dataclasses import dataclass

from pydantic import ValidationError

from ..errors import ApiError, StartupError
from .drill_models import (
    CancelRecoveryDrillRequest,
    CreateRecoveryDrillRequest,
    RecoveryDrill,
    RecoveryDrillExecution,
    RecoveryDrillReceipt,
    RecoveryDrillSchedule,
    UpdateRecoveryDrillScheduleRequest,
)


MAX_DRILLS = 64
SCHEDULE_SECONDS = 30 * 24 * 60 * 60
SCOPE = [
    "coreDatabase",
    "vaultKey",
    "configuration",
    "familyBoard",
    "componentData",
]
_ID = re.compile(r"^[0-9a-f]{32}$")


@dataclass(frozen=True)
class RecoveryDrillAuthority:
    actor_id: str
    actor_revision: int
    family_id: str
    scheduled: bool


class RecoveryDrillBackend:
    def execute(self, authority, *, deadline, cancelled):
        raise NotImplementedError


def _request_hash(body):
    value = body.model_dump(mode="json")
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode("ascii")
    ).hexdigest()


class RecoveryDrillManagement:
    def __init__(self, db, auth, settings, backend=None, *, monotonic=time.monotonic):
        self.db, self.auth, self.settings = db, auth, settings
        self.backend = backend
        self._monotonic = monotonic

    def _assert_admin(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT revision,role,disabled,must_change_password FROM users WHERE id=?",
            (actor.id,),
        ).fetchone()
        if (
            row is None
            or row["role"] != "admin"
            or row["disabled"]
            or row["must_change_password"]
        ):
            raise ApiError("forbidden", 403)
        return row["revision"]

    @staticmethod
    def _body(value, model):
        try:
            return model.model_validate(value.model_dump(mode="python"))
        except (AttributeError, TypeError, ValidationError, ValueError):
            raise ApiError("invalid_request") from None

    @staticmethod
    def _identifier(value):
        if type(value) is not str or _ID.fullmatch(value) is None:
            raise ApiError("invalid_request")

    @staticmethod
    def _receipt(row):
        if row["receipt_json"] is None:
            return None
        try:
            return RecoveryDrillReceipt.model_validate_json(row["receipt_json"])
        except (TypeError, ValidationError, ValueError):
            raise ApiError("recovery_drill_storage_unavailable", 503) from None

    @classmethod
    def _public(cls, row):
        try:
            return RecoveryDrill(
                id=row["id"],
                requestId=row["request_id"],
                contractVersion=1,
                mode="isolated_full_restore",
                trigger="monthly" if row["scheduled"] else "manual",
                scope=SCOPE,
                deadlineSeconds=row["deadline_seconds"],
                revision=row["revision"],
                state=row["state"],
                cancelRequested=bool(row["cancel_requested"]),
                createdAt=row["created_at"],
                updatedAt=row["updated_at"],
                receipt=cls._receipt(row),
            )
        except (TypeError, ValidationError, ValueError):
            raise ApiError("recovery_drill_storage_unavailable", 503) from None

    @staticmethod
    def _find(connection, identifier):
        row = connection.execute(
            "SELECT * FROM core_recovery_drills WHERE id=?", (identifier,)
        ).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        return row

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM core_recovery_drills ORDER BY sequence LIMIT ?",
                    (MAX_DRILLS + 1,),
                ).fetchall()
                if len(rows) > MAX_DRILLS:
                    raise ValueError("too_many_drills")
                active = 0
                for row in rows:
                    if (
                        type(row["request_hash"]) is not str
                        or len(row["request_hash"]) != 64
                        or row["updated_at"] < row["created_at"]
                    ):
                        raise ValueError("invalid_drill")
                    self._public(row)
                    active += row["state"] in {"queued", "running"}
                if active > 1:
                    raise ValueError("too_many_active_drills")
                schedule = connection.execute(
                    "SELECT * FROM core_recovery_drill_schedule WHERE id=1"
                ).fetchone()
                if schedule is not None:
                    self._schedule(schedule)
        except (ApiError, sqlite3.Error, TypeError, ValueError):
            raise StartupError("invalid_core_recovery_drills_storage") from None

    @staticmethod
    def _schedule(row):
        try:
            return RecoveryDrillSchedule(
                contractVersion=1,
                revision=0 if row is None else row["revision"],
                enabled=False if row is None else bool(row["enabled"]),
                intervalDays=30,
                nextRunAt=None if row is None else row["next_run_at"],
            )
        except (TypeError, ValidationError, ValueError):
            raise ApiError("recovery_drill_storage_unavailable", 503) from None

    def get_schedule(self, actor):
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            row = connection.execute(
                "SELECT * FROM core_recovery_drill_schedule WHERE id=1"
            ).fetchone()
            return {"schedule": self._schedule(row)}

    def update_schedule(self, actor, body):
        body = self._body(body, UpdateRecoveryDrillScheduleRequest)
        with self.db.transaction() as connection:
            actor_revision = self._assert_admin(connection, actor)
            current = connection.execute(
                "SELECT * FROM core_recovery_drill_schedule WHERE id=1"
            ).fetchone()
            revision = 0 if current is None else current["revision"]
            if revision != body.expectedRevision:
                raise ApiError("revision_conflict", 409)
            now = int(self.settings.clock())
            next_run = now + SCHEDULE_SECONDS if body.enabled else None
            if current is None:
                connection.execute(
                    "INSERT INTO core_recovery_drill_schedule("
                    "id,revision,enabled,next_run_at,actor_id,actor_revision,"
                    "family_id,updated_at) VALUES(1,1,?,?,?,?,?,?)",
                    (
                        int(body.enabled),
                        next_run,
                        actor.id,
                        actor_revision,
                        actor.family_id,
                        now,
                    ),
                )
            else:
                connection.execute(
                    "UPDATE core_recovery_drill_schedule SET revision=revision+1,"
                    "enabled=?,next_run_at=?,actor_id=?,actor_revision=?,"
                    "family_id=?,updated_at=? WHERE id=1",
                    (
                        int(body.enabled),
                        next_run,
                        actor.id,
                        actor_revision,
                        actor.family_id,
                        now,
                    ),
                )
            saved = connection.execute(
                "SELECT * FROM core_recovery_drill_schedule WHERE id=1"
            ).fetchone()
            return {"schedule": self._schedule(saved)}

    def create(self, actor, body):
        body = self._body(body, CreateRecoveryDrillRequest)
        digest = _request_hash(body)
        with self.db.transaction() as connection:
            actor_revision = self._assert_admin(connection, actor)
            previous = connection.execute(
                "SELECT * FROM core_recovery_drills "
                "WHERE actor_id=? AND request_id=?",
                (actor.id, body.requestId),
            ).fetchone()
            if previous is not None:
                if previous["request_hash"] != digest:
                    raise ApiError("recovery_drill_conflict", 409)
                return {"drill": self._public(previous)}
            if connection.execute(
                "SELECT 1 FROM core_recovery_drills "
                "WHERE state IN ('queued','running') LIMIT 1"
            ).fetchone():
                raise ApiError("recovery_drill_busy", 409)
            count = connection.execute(
                "SELECT COUNT(*) FROM core_recovery_drills"
            ).fetchone()[0]
            if count >= MAX_DRILLS:
                remove = count - MAX_DRILLS + 1
                deleted = connection.execute(
                    "DELETE FROM core_recovery_drills WHERE id IN ("
                    "SELECT id FROM core_recovery_drills "
                    "WHERE state IN ('succeeded','failed','cancelled') "
                    "ORDER BY sequence LIMIT ?)",
                    (remove,),
                ).rowcount
                if deleted != remove:
                    raise ApiError("recovery_drill_limit_reached", 409)
            now = int(self.settings.clock())
            sequence = connection.execute(
                "SELECT COALESCE(MAX(sequence),0)+1 FROM core_recovery_drills"
            ).fetchone()[0]
            identifier = uuid.uuid4().hex
            connection.execute(
                "INSERT INTO core_recovery_drills("
                "id,sequence,revision,actor_id,actor_revision,family_id,request_id,"
                "request_hash,deadline_seconds,scheduled,state,cancel_requested,created_at,"
                "updated_at,receipt_json) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)",
                (
                    identifier,
                    sequence,
                    1,
                    actor.id,
                    actor_revision,
                    actor.family_id,
                    body.requestId,
                    digest,
                    body.deadlineSeconds,
                    0,
                    "queued",
                    0,
                    now,
                    now,
                ),
            )
            return {
                "drill": self._public(self._find(connection, identifier))
            }

    def get(self, actor, identifier):
        self._identifier(identifier)
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            return {"drill": self._public(self._find(connection, identifier))}

    def list(self, actor, *, before=None, limit=20):
        if (
            type(limit) is not int
            or not 1 <= limit <= 20
            or before is not None
            and (type(before) is not int or not 1 <= before <= 2**63 - 1)
        ):
            raise ApiError("invalid_request")
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            rows = connection.execute(
                "SELECT * FROM core_recovery_drills WHERE sequence<? "
                "ORDER BY sequence DESC LIMIT ?",
                (before if before is not None else 2**63 - 1, limit + 1),
            ).fetchall()
            return {
                "drills": [self._public(row) for row in rows[:limit]],
                "nextBefore": rows[limit - 1]["sequence"] if len(rows) > limit else None,
            }

    def cancel(self, actor, identifier, body):
        self._identifier(identifier)
        body = self._body(body, CancelRecoveryDrillRequest)
        with self.db.transaction() as connection:
            self._assert_admin(connection, actor)
            row = self._find(connection, identifier)
            if row["revision"] != body.expectedRevision:
                raise ApiError("revision_conflict", 409)
            if row["state"] not in {"queued", "running"} or row["cancel_requested"]:
                return {"drill": self._public(row)}
            now = max(row["updated_at"], int(self.settings.clock()))
            if row["state"] == "queued":
                receipt = RecoveryDrillReceipt(
                    contractVersion=1,
                    outcome="cancelled",
                    effectPolicy="deny_all_production_effects",
                    startedAt=row["created_at"],
                    completedAt=now,
                    durationMilliseconds=0,
                    verifiedResources=[],
                    failureCode="cancelled",
                ).model_dump_json()
                connection.execute(
                    "UPDATE core_recovery_drills SET revision=revision+1,state='cancelled',"
                    "cancel_requested=1,updated_at=?,receipt_json=? WHERE id=?",
                    (now, receipt, identifier),
                )
            else:
                connection.execute(
                    "UPDATE core_recovery_drills SET revision=revision+1,"
                    "cancel_requested=1,updated_at=? WHERE id=?",
                    (now, identifier),
                )
            return {
                "drill": self._public(self._find(connection, identifier))
            }

    def _dispatch_authorized(self, connection, row):
        current = connection.execute(
            "SELECT u.revision,u.role,u.disabled,u.must_change_password,"
            "f.revoked_at,f.expires_at FROM users u JOIN session_families f "
            "ON f.user_id=u.id WHERE u.id=? AND f.id=?",
            (row["actor_id"], row["family_id"]),
        ).fetchone()
        account_valid = bool(
            current
            and current["revision"] == row["actor_revision"]
            and current["role"] == "admin"
            and not current["disabled"]
            and not current["must_change_password"]
        )
        return account_valid and bool(
            row["scheduled"]
            or current["revoked_at"] is None
            and current["expires_at"] > self.settings.clock()
        )

    @staticmethod
    def _terminal_receipt(row, *, outcome, now, failure, verified=()):
        elapsed = max(0, now - row["updated_at"])
        return RecoveryDrillReceipt(
            contractVersion=1,
            outcome=outcome,
            effectPolicy="deny_all_production_effects",
            startedAt=row["updated_at"],
            completedAt=now,
            durationMilliseconds=min(elapsed * 1000, 3_600_000),
            verifiedResources=list(verified),
            failureCode=failure,
        )

    @classmethod
    def _finish(cls, connection, row, receipt):
        connection.execute(
            "UPDATE core_recovery_drills SET revision=revision+1,state=?,"
            "cancel_requested=?,updated_at=?,receipt_json=? WHERE id=?",
            (
                receipt.outcome,
                int(receipt.outcome == "cancelled"),
                receipt.completedAt,
                receipt.model_dump_json(),
                row["id"],
            ),
        )
        updated = cls._find(connection, row["id"])
        return {"drill": cls._public(updated)}

    def _cancelled(self, identifier):
        with self.db.connection() as connection:
            row = connection.execute(
                "SELECT state,cancel_requested FROM core_recovery_drills WHERE id=?",
                (identifier,),
            ).fetchone()
            return bool(
                row is None
                or row["cancel_requested"]
                or row["state"] != "running"
            )

    def _dispatch_lock(self):
        class Lease:
            def __init__(self, owner):
                self.owner, self.descriptor = owner, None

            def __enter__(self):
                try:
                    self.descriptor = os.open(
                        self.owner.settings.data_dir / ".recovery-drills.lock",
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
                    import fcntl

                    try:
                        fcntl.flock(
                            self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB
                        )
                    except BlockingIOError:
                        return False
                    return True
                except OSError:
                    raise ApiError(
                        "recovery_drill_storage_unavailable", 503
                    ) from None

            def __exit__(self, *_args):
                if self.descriptor is not None:
                    os.close(self.descriptor)

        return Lease(self)

    def _enqueue_due(self, connection):
        now = int(self.settings.clock())
        schedule = connection.execute(
            "SELECT * FROM core_recovery_drill_schedule "
            "WHERE id=1 AND enabled=1 AND next_run_at<=?",
            (now,),
        ).fetchone()
        if schedule is None or connection.execute(
            "SELECT 1 FROM core_recovery_drills "
            "WHERE state IN ('queued','running') LIMIT 1"
        ).fetchone():
            return
        request = CreateRecoveryDrillRequest(
            contractVersion=1,
            requestId=uuid.uuid4().hex,
            mode="isolated_full_restore",
            deadlineSeconds=3600,
        )
        count = connection.execute(
            "SELECT COUNT(*) FROM core_recovery_drills"
        ).fetchone()[0]
        if count >= MAX_DRILLS:
            connection.execute(
                "DELETE FROM core_recovery_drills WHERE id IN ("
                "SELECT id FROM core_recovery_drills "
                "WHERE state IN ('succeeded','failed','cancelled') "
                "ORDER BY sequence LIMIT ?)",
                (count - MAX_DRILLS + 1,),
            )
        sequence = connection.execute(
            "SELECT COALESCE(MAX(sequence),0)+1 FROM core_recovery_drills"
        ).fetchone()[0]
        connection.execute(
            "INSERT INTO core_recovery_drills("
            "id,sequence,revision,actor_id,actor_revision,family_id,request_id,"
            "request_hash,deadline_seconds,scheduled,state,cancel_requested,created_at,"
            "updated_at,receipt_json) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)",
            (
                uuid.uuid4().hex,
                sequence,
                1,
                schedule["actor_id"],
                schedule["actor_revision"],
                schedule["family_id"],
                request.requestId,
                _request_hash(request),
                request.deadlineSeconds,
                1,
                "queued",
                0,
                now,
                now,
            ),
        )
        next_run = schedule["next_run_at"]
        while next_run <= now:
            next_run += SCHEDULE_SECONDS
        connection.execute(
            "UPDATE core_recovery_drill_schedule SET revision=revision+1,"
            "next_run_at=?,updated_at=? WHERE id=1",
            (next_run, now),
        )

    def tick(self):
        """Advance one read-only drill; an interrupted run is safe to repeat."""
        with self._dispatch_lock() as acquired:
            if not acquired:
                return None
            with self.db.transaction() as connection:
                self._enqueue_due(connection)
                row = connection.execute(
                    "SELECT * FROM core_recovery_drills "
                    "WHERE state IN ('running','queued') "
                    "ORDER BY CASE state WHEN 'running' THEN 0 ELSE 1 END,"
                    "sequence LIMIT 1"
                ).fetchone()
                if row is None:
                    return None
                now = int(self.settings.clock())
                if row["cancel_requested"]:
                    receipt = self._terminal_receipt(
                        row,
                        outcome="cancelled",
                        now=now,
                        failure="cancelled",
                    )
                    return self._finish(connection, row, receipt)
                if not self._dispatch_authorized(connection, row):
                    receipt = self._terminal_receipt(
                        row,
                        outcome="failed",
                        now=now,
                        failure="authority_changed",
                    )
                    return self._finish(connection, row, receipt)
                expires_at = row["created_at"] + row["deadline_seconds"]
                if now >= expires_at:
                    receipt = self._terminal_receipt(
                        row,
                        outcome="failed",
                        now=now,
                        failure="deadline_exceeded",
                    )
                    return self._finish(connection, row, receipt)
                if self.backend is None:
                    receipt = self._terminal_receipt(
                        row,
                        outcome="failed",
                        now=now,
                        failure="worker_unavailable",
                    )
                    return self._finish(connection, row, receipt)
                if row["state"] == "queued":
                    connection.execute(
                        "UPDATE core_recovery_drills SET revision=revision+1,"
                        "state='running',updated_at=? WHERE id=?",
                        (now, row["id"]),
                    )
                    row = self._find(connection, row["id"])
                authority = RecoveryDrillAuthority(
                    actor_id=row["actor_id"],
                    actor_revision=row["actor_revision"],
                    family_id=row["family_id"],
                    scheduled=bool(row["scheduled"]),
                )
                identifier = row["id"]
                remaining = max(0.0, expires_at - self.settings.clock())
            try:
                raw = self.backend.execute(
                    authority,
                    deadline=self._monotonic() + remaining,
                    cancelled=lambda: self._cancelled(identifier),
                )
                result = RecoveryDrillExecution.model_validate(
                    raw.model_dump(mode="python")
                )
            except BaseException as error:
                if isinstance(error, (KeyboardInterrupt, SystemExit)):
                    raise
                result = RecoveryDrillExecution(
                    succeeded=False,
                    verifiedResources=[],
                    failureCode="worker_unavailable",
                )
            with self.db.transaction() as connection:
                current = self._find(connection, identifier)
                if current["state"] != "running":
                    return {"drill": self._public(current)}
                now = int(self.settings.clock())
                if current["cancel_requested"]:
                    receipt = self._terminal_receipt(
                        current,
                        outcome="cancelled",
                        now=now,
                        failure="cancelled",
                        verified=result.verifiedResources,
                    )
                else:
                    receipt = self._terminal_receipt(
                        current,
                        outcome="succeeded" if result.succeeded else "failed",
                        now=now,
                        failure=result.failureCode,
                        verified=result.verifiedResources,
                    )
                return self._finish(connection, current, receipt)
