import hashlib
import json
import re
import sqlite3
import uuid

from pydantic import ValidationError

from ..errors import ApiError, StartupError
from .drill_models import (
    CancelRecoveryDrillRequest,
    CreateRecoveryDrillRequest,
    RecoveryDrill,
    RecoveryDrillReceipt,
)


MAX_DRILLS = 64
SCOPE = [
    "coreDatabase",
    "vaultKey",
    "configuration",
    "familyBoard",
    "componentData",
]
_ID = re.compile(r"^[0-9a-f]{32}$")


def _request_hash(body):
    value = body.model_dump(mode="json")
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode("ascii")
    ).hexdigest()


class RecoveryDrillManagement:
    def __init__(self, db, auth, settings):
        self.db, self.auth, self.settings = db, auth, settings

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
        except (ApiError, sqlite3.Error, TypeError, ValueError):
            raise StartupError("invalid_core_recovery_drills_storage") from None

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
                "request_hash,deadline_seconds,state,cancel_requested,created_at,"
                "updated_at,receipt_json) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)",
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
