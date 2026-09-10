"""Tamper-evident persistent status and audit chain; contains no confirm tokens."""

import hashlib
import hmac
import json
import re
import sqlite3

from ..errors import ApiError, StartupError
from . import schema


def _json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def _signed(key, domain, value):
    return hmac.new(key, domain + _json(value), hashlib.sha256).hexdigest()


def state_tag(scope, chain_id, sequence, head, key=None):
    if key is None:
        raise TypeError("key required")
    return _signed(key, b"larenor-keenetic-command-state-v1\0", [
        scope.coreId, scope.homeId, chain_id, sequence, head
    ])


class KeeneticCommandJournal:
    def __init__(self, db, auth, settings, key, scope):
        self.db, self.auth, self.settings = db, auth, settings
        self.key, self.scope = key, scope
        try:
            self.recover_unfinished()
        except ApiError:
            raise StartupError("keenetic_command_storage_invalid") from None

    def _state_tag(self, scope, chain_id, sequence, head):
        return state_tag(scope, chain_id, sequence, head, self.key)

    def _verify(self, connection):
        try:
            state = connection.execute("SELECT * FROM keenetic_command_chain_state").fetchall()
            if len(state) != 1:
                raise ValueError()
            state = state[0]
            if (
                state["singleton"] != 1
                or not re.fullmatch(r"[0-9a-f]{32}", state["chain_id"] or "")
                or type(state["sequence"]) is not int
                or not 0 <= state["sequence"] <= schema.MAX_EVENTS
                or not re.fullmatch(r"[0-9a-f]{64}", state["head_hash"] or "")
                or not hmac.compare_digest(
                    state["authentication_tag"],
                    self._state_tag(
                        self.scope, state["chain_id"], state["sequence"], state["head_hash"]
                    ),
                )
            ):
                raise ValueError()
            previous = schema.ZERO
            rows = connection.execute(
                "SELECT * FROM keenetic_command_events ORDER BY sequence LIMIT ?",
                (schema.MAX_EVENTS + 1,),
            ).fetchall()
            if len(rows) != state["sequence"]:
                raise ValueError()
            latest = {}
            for index, row in enumerate(rows, 1):
                payload = json.loads(row["payload_json"])
                canonical = _json(payload).decode("ascii")
                value = [
                    self.scope.coreId,
                    self.scope.homeId,
                    state["chain_id"],
                    index,
                    row["request_id"],
                    row["actor_id"],
                    row["resource_id"],
                    row["status"],
                    canonical,
                    previous,
                    row["created_at"],
                ]
                expected = hashlib.sha256(
                    b"larenor-keenetic-command-event-v1\0" + _json(value)
                ).hexdigest()
                if (
                    row["sequence"] != index
                    or row["previous_hash"] != previous
                    or row["entry_hash"] != expected
                    or canonical != row["payload_json"]
                    or payload.get("requestId") != row["request_id"]
                    or payload.get("status") != row["status"]
                ):
                    raise ValueError()
                latest[row["request_id"]] = payload
                previous = expected
            if previous != state["head_hash"]:
                raise ValueError()
            records = connection.execute("SELECT * FROM keenetic_command_records").fetchall()
            if len(records) > schema.MAX_COMMANDS or len(latest) != len(records):
                raise ValueError()
            for record in records:
                payload = latest.get(record["request_id"])
                target = json.loads(record["target_json"])
                if (
                    payload is None
                    or payload["status"] != record["status"]
                    or payload["target"] != target
                    or _json(target).decode("ascii") != record["target_json"]
                ):
                    raise ValueError()
            return state
        except (ValueError, TypeError, KeyError, json.JSONDecodeError, sqlite3.Error):
            raise ApiError("keenetic_command_integrity_failed", 503) from None

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                self._verify(connection)
        except ApiError:
            raise StartupError("keenetic_command_storage_invalid") from None

    def _append(self, connection, *, actor_id, request_id, resource_id, status, payload, verified=False):
        state = (
            connection.execute("SELECT * FROM keenetic_command_chain_state").fetchone()
            if verified
            else self._verify(connection)
        )
        sequence = state["sequence"] + 1
        if sequence > schema.MAX_EVENTS:
            raise ApiError("keenetic_command_limit", 429)
        now = self.settings.clock()
        canonical = _json(payload).decode("ascii")
        value = [self.scope.coreId, self.scope.homeId, state["chain_id"], sequence,
                 request_id, actor_id, resource_id, status, canonical,
                 state["head_hash"], now]
        head = hashlib.sha256(
            b"larenor-keenetic-command-event-v1\0" + _json(value)
        ).hexdigest()
        connection.execute(
            "INSERT INTO keenetic_command_events VALUES(?,?,?,?,?,?,?,?,?)",
            (sequence, request_id, actor_id, resource_id, status, canonical,
             state["head_hash"], head, now),
        )
        connection.execute(
            "UPDATE keenetic_command_chain_state SET sequence=?,head_hash=?,authentication_tag=? WHERE singleton=1",
            (sequence, head, self._state_tag(self.scope, state["chain_id"], sequence, head)),
        )

    @staticmethod
    def _public(row):
        return {
            "requestId": row["request_id"],
            "action": row["action"],
            "status": row["status"],
            "target": json.loads(row["target_json"]),
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
        }

    def _current_admin(self, connection, actor):
        self.auth.assert_current(connection, actor)
        if actor.role != "admin" or actor.must_change_password:
            raise ApiError("forbidden", 403)

    def accept(self, actor, body):
        target = body.target.model_dump()
        canonical = _json(target).decode("ascii")
        digest = hmac.new(self.key, body.idempotencyKey.encode("ascii"), hashlib.sha256).hexdigest()
        with self.db.transaction() as connection:
            self._current_admin(connection, actor)
            self._verify(connection)
            old = connection.execute(
                "SELECT * FROM keenetic_command_records WHERE actor_id=? AND idempotency_hash=?",
                (actor.id, digest),
            ).fetchone()
            if old is not None:
                if old["request_id"] != body.requestId or old["target_json"] != canonical or old["action"] != body.action:
                    raise ApiError("idempotency_conflict", 409)
                return self._public(old)
            count = connection.execute("SELECT COUNT(*) FROM keenetic_command_records").fetchone()[0]
            if count >= schema.MAX_COMMANDS:
                raise ApiError("keenetic_command_limit", 429)
            now = self.settings.clock()
            connection.execute(
                "INSERT INTO keenetic_command_records VALUES(?,?,?,?,?,?,?,?,?)",
                (body.requestId, actor.id, digest, body.target.resourceId, body.action,
                 "accepted", canonical, now, now),
            )
            payload = {"requestId": body.requestId, "action": body.action,
                       "status": "accepted", "target": target, "code": "accepted"}
            self._append(connection, actor_id=actor.id, request_id=body.requestId,
                         resource_id=body.target.resourceId, status="accepted", payload=payload,
                         verified=True)
            return {**payload, "createdAt": now, "updatedAt": now}

    def transition(self, actor, body, status, code):
        with self.db.transaction() as connection:
            self._current_admin(connection, actor)
            self._verify(connection)
            row = connection.execute(
                "SELECT * FROM keenetic_command_records WHERE request_id=?", (body.requestId,)
            ).fetchone()
            if row is None or row["actor_id"] != actor.id or row["action"] != body.action:
                raise ApiError("keenetic_command_changed", 409)
            allowed = {
                "accepted": {"executing", "cancelled", "failed"},
                "executing": {"succeeded", "failed", "unknown"},
            }
            if status not in allowed.get(row["status"], set()):
                if status == row["status"]:
                    return self._public(row)
                raise ApiError("keenetic_command_changed", 409)
            now = self.settings.clock()
            connection.execute(
                "UPDATE keenetic_command_records SET status=?,updated_at=? WHERE request_id=?",
                (status, now, body.requestId),
            )
            target = json.loads(row["target_json"])
            payload = {"requestId": body.requestId, "action": body.action,
                       "status": status, "target": target, "code": code}
            self._append(connection, actor_id=actor.id, request_id=body.requestId,
                         resource_id=row["resource_id"], status=status, payload=payload,
                         verified=True)
            return {**payload, "createdAt": row["created_at"], "updatedAt": now}

    def status(self, actor, request_id):
        with self.db.connection() as connection:
            self._current_admin(connection, actor)
            self._verify(connection)
            row = connection.execute(
                "SELECT * FROM keenetic_command_records WHERE request_id=?", (request_id,)
            ).fetchone()
            if row is None:
                raise ApiError("not_found", 404)
            return {"command": self._public(row)}

    def history(self, actor, resource_id=None, limit=50):
        if type(limit) is not int or not 1 <= limit <= 50:
            raise ApiError("invalid_request")
        with self.db.connection() as connection:
            self._current_admin(connection, actor)
            state = self._verify(connection)
            rows = connection.execute(
                "SELECT payload_json,sequence FROM keenetic_command_events "
                + ("WHERE resource_id=? " if resource_id else "")
                + "ORDER BY sequence LIMIT ?",
                ((resource_id, limit) if resource_id else (limit,)),
            ).fetchall()
            return {"events": [json.loads(row["payload_json"]) | {"sequence": row["sequence"]} for row in rows],
                    "verified": True, "headSequence": state["sequence"]}

    def integrity(self, actor):
        with self.db.connection() as connection:
            self._current_admin(connection, actor)
            state = self._verify(connection)
            checkpoint = _signed(self.key, b"larenor-keenetic-command-checkpoint-v1\0", [
                self.scope.coreId, self.scope.homeId, state["chain_id"],
                state["sequence"], state["head_hash"]
            ])
            return {"integrity": {"schemaVersion": 1, "verified": True,
                    "chainId": state["chain_id"], "sequence": state["sequence"],
                    "headHash": state["head_hash"], "checkpoint": checkpoint}}

    def recover_unfinished(self):
        with self.db.transaction() as connection:
            self._verify(connection)
            rows = connection.execute(
                "SELECT * FROM keenetic_command_records WHERE status IN ('accepted','executing')"
            ).fetchall()
            for row in rows:
                now = self.settings.clock()
                connection.execute(
                    "UPDATE keenetic_command_records SET status='unknown',updated_at=? WHERE request_id=?",
                    (now, row["request_id"]),
                )
                payload = {"requestId": row["request_id"], "action": row["action"],
                           "status": "unknown", "target": json.loads(row["target_json"]),
                           "code": "keenetic_command_interrupted"}
                self._append(connection, actor_id=row["actor_id"], request_id=row["request_id"],
                             resource_id=row["resource_id"], status="unknown", payload=payload,
                             verified=True)
