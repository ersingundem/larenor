"""Deterministic device-write arbitration with durable ownership receipts."""

import hashlib
import hmac
import json
import sqlite3
import uuid

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from . import schema


class RuleArbitrationService:
    """Owns Core write ordering; external Home Assistant writes stay observational."""

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings = db, auth, settings
        self.scope = HomeScope.model_validate(context.model_dump())
        self._key = hmac.new(
            key,
            b"larenor-rule-arbitration-v1\0"
            + self.scope.coreId.encode("ascii")
            + b"\0"
            + self.scope.homeId.encode("ascii"),
            hashlib.sha256,
        ).digest()

    @staticmethod
    def _json(value):
        return json.dumps(
            value, ensure_ascii=True, allow_nan=False, separators=(",", ":"), sort_keys=True
        ).encode("ascii")

    def _tag(self, domain, values):
        return hmac.new(
            self._key, domain + b"\0" + self._json(values), hashlib.sha256
        ).hexdigest()

    def _decision_tag(self, row):
        return self._tag(b"decision", [row[name] for name in (
            "id", "owner_id", "family_id", "request_key", "request_hash",
            "device_id", "expected_device_revision", "source", "rule_id",
            "rule_revision", "priority", "action", "revision", "state", "reason",
            "created_at", "expires_at", "completed_at", "readback_device_revision",
        )])

    def _ownership_tag(self, row):
        return self._tag(b"ownership", [row[name] for name in (
            "device_id", "revision", "decision_id", "source", "rule_id", "owner_id",
            "priority", "action", "expires_at",
        )])

    def _observation_tag(self, row):
        return self._tag(b"observation", [row[name] for name in (
            "id", "reporter_id", "family_id", "device_id", "provider_revision",
            "action", "observed_at", "recorded_at", "matches_decision", "control_mode",
        )])

    def _verified(self, row, tagger):
        if row is None:
            raise ApiError("not_found", 404)
        tag = row["envelope_tag"]
        if (
            not isinstance(tag, str)
            or len(tag) != 64
            or any(char not in "0123456789abcdef" for char in tag)
            or not hmac.compare_digest(tag, tagger(row))
        ):
            raise StartupError("rule_arbiter_storage_invalid")
        return row

    def _inventory(self, connection):
        groups = []
        for table, maximum, tagger in (
            ("rule_arbiter_decisions", schema.MAX_DECISIONS, self._decision_tag),
            ("rule_arbiter_ownership", schema.MAX_DEVICES, self._ownership_tag),
            ("rule_arbiter_observations", schema.MAX_OBSERVATIONS, self._observation_tag),
        ):
            rows = connection.execute(
                f"SELECT * FROM {table} ORDER BY 1 LIMIT ?", (maximum + 1,)
            ).fetchall()
            if len(rows) > maximum:
                raise StartupError("rule_arbiter_storage_invalid")
            for row in rows:
                self._verified(row, tagger)
            groups.append(rows)
        return groups

    def _state_tag(self, groups):
        return self._tag(b"inventory", [
            [[row[0], row["envelope_tag"]] for row in rows] for rows in groups
        ])

    def _refresh_state(self, connection):
        groups = self._inventory(connection)
        connection.execute(
            "UPDATE rule_arbiter_state SET decision_count=?,ownership_count=?,"
            "observation_count=?,inventory_tag=? WHERE singleton=1",
            (*[len(rows) for rows in groups], self._state_tag(groups)),
        )

    def _validate(self, connection):
        groups = self._inventory(connection)
        rows = connection.execute("SELECT * FROM rule_arbiter_state").fetchall()
        if len(rows) != 1:
            raise StartupError("rule_arbiter_storage_invalid")
        state = rows[0]
        state_tag = state["inventory_tag"]
        if (
            state["singleton"] != 1
            or [state["decision_count"], state["ownership_count"], state["observation_count"]]
            != [len(rows) for rows in groups]
            or not isinstance(state_tag, str)
            or len(state_tag) != 64
            or any(char not in "0123456789abcdef" for char in state_tag)
            or not hmac.compare_digest(state_tag, self._state_tag(groups))
            or connection.execute(
                "PRAGMA foreign_key_check(rule_arbiter_ownership)"
            ).fetchone() is not None
        ):
            raise StartupError("rule_arbiter_storage_invalid")
        return groups

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                self._validate(connection)
        except StartupError:
            raise
        except (sqlite3.Error, TypeError, ValueError, json.JSONDecodeError):
            raise StartupError("rule_arbiter_storage_invalid") from None

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    def _actor(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT revision,role,disabled,must_change_password FROM users WHERE id=?",
            (actor.id,),
        ).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("invalid_session", 401)
        return row

    @staticmethod
    def _request_hash(body):
        return hashlib.sha256(body.model_dump_json().encode("utf-8")).hexdigest()

    def _effect_token(self, row):
        return self._tag(b"effect", [row[name] for name in (
            "id", "device_id", "expected_device_revision", "source", "rule_id",
            "rule_revision", "priority", "action", "created_at", "expires_at",
        )])

    def _public_decision(self, row, now):
        should_write = row["state"] == "authorized" and now < row["expires_at"]
        return {
            "schemaVersion": 1,
            "id": row["id"],
            "revision": row["revision"],
            "deviceId": row["device_id"],
            "expectedDeviceRevision": row["expected_device_revision"],
            "source": row["source"],
            "ruleId": row["rule_id"],
            "ruleRevision": row["rule_revision"],
            "priority": row["priority"],
            "action": row["action"],
            "state": row["state"],
            "reason": row["reason"],
            "createdAt": row["created_at"],
            "expiresAt": row["expires_at"],
            "completedAt": row["completed_at"],
            "readbackDeviceRevision": row["readback_device_revision"],
            "shouldWrite": should_write,
            "effectToken": self._effect_token(row) if should_write else None,
        }

    def _ownership(self, connection, device_id):
        row = connection.execute(
            "SELECT * FROM rule_arbiter_ownership WHERE device_id=?", (device_id,)
        ).fetchone()
        return None if row is None else self._verified(row, self._ownership_tag)

    def _replace_ownership(self, connection, old, decision):
        revision = 1 if old is None else old["revision"] + 1
        row = {
            "device_id": decision["device_id"], "revision": revision,
            "decision_id": decision["id"], "source": decision["source"],
            "rule_id": decision["rule_id"], "owner_id": decision["owner_id"],
            "priority": decision["priority"], "action": decision["action"],
            "expires_at": decision["expires_at"],
        }
        row["envelope_tag"] = self._ownership_tag(row)
        connection.execute(
            "INSERT INTO rule_arbiter_ownership VALUES(?,?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(device_id) DO UPDATE SET revision=excluded.revision,"
            "decision_id=excluded.decision_id,source=excluded.source,rule_id=excluded.rule_id,"
            "owner_id=excluded.owner_id,priority=excluded.priority,action=excluded.action,"
            "expires_at=excluded.expires_at,envelope_tag=excluded.envelope_tag",
            tuple(row.values()),
        )

    def _supersede(self, connection, decision_id, now):
        prior = self._verified(connection.execute(
            "SELECT * FROM rule_arbiter_decisions WHERE id=?", (decision_id,)
        ).fetchone(), self._decision_tag)
        if prior["state"] != "authorized":
            return
        row = dict(prior)
        row.update(
            revision=row["revision"] + 1,
            state="superseded",
            reason="replaced",
            completed_at=now,
        )
        row["envelope_tag"] = self._decision_tag(row)
        connection.execute(
            "UPDATE rule_arbiter_decisions SET revision=?,state=?,reason=?,completed_at=?,"
            "envelope_tag=? WHERE id=?",
            (row["revision"], row["state"], row["reason"], row["completed_at"],
             row["envelope_tag"], row["id"]),
        )

    def _submit(self, actor, core_id, home_id, body, *, source):
        self._scope(core_id, home_id)
        now = self.settings.clock()
        request_hash = self._request_hash(body)
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            self._validate(connection)
            existing = connection.execute(
                "SELECT * FROM rule_arbiter_decisions WHERE owner_id=? AND family_id=? "
                "AND request_key=?", (actor.id, actor.family_id, body.requestKey)
            ).fetchone()
            if existing is not None:
                existing = self._verified(existing, self._decision_tag)
                if existing["request_hash"] != request_hash or existing["source"] != source:
                    raise ApiError("idempotency_conflict", 409)
                return {"decision": self._public_decision(existing, now)}
            count = connection.execute(
                "SELECT COUNT(*) FROM rule_arbiter_decisions"
            ).fetchone()[0]
            if count >= schema.MAX_DECISIONS:
                raise ApiError("rule_arbiter_limit_reached", 429)
            active = self._ownership(connection, body.deviceId)
            active_now = active is not None and now < active["expires_at"]
            priority = 101 if source == "manual" else body.priority
            wins = not active_now
            reason = "winner"
            if active_now and source == "manual":
                wins = True
            elif active_now and active["source"] == "manual":
                reason = "active_manual"
            elif active_now and priority > active["priority"]:
                wins = True
            elif active_now and priority < active["priority"]:
                reason = "lower_priority"
            elif active_now and (
                active["rule_id"] == getattr(body, "ruleId", None)
                and active["owner_id"] == actor.id
            ):
                wins = True
            elif active_now:
                reason = "equal_priority"
            row = {
                "id": uuid.uuid4().hex, "owner_id": actor.id,
                "family_id": actor.family_id, "request_key": body.requestKey,
                "request_hash": request_hash, "device_id": body.deviceId,
                "expected_device_revision": body.expectedDeviceRevision,
                "source": source, "rule_id": getattr(body, "ruleId", None),
                "rule_revision": getattr(body, "expectedRuleRevision", None),
                "priority": priority, "action": body.action, "revision": 1,
                "state": "authorized" if wins else "suppressed",
                "reason": reason, "created_at": now,
                "expires_at": now
                + (body.holdSeconds if source == "manual" else body.leaseSeconds),
                "completed_at": None if wins else now,
                "readback_device_revision": None,
            }
            row["envelope_tag"] = self._decision_tag(row)
            connection.execute(
                "INSERT INTO rule_arbiter_decisions "
                "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                tuple(row.values()),
            )
            if wins:
                if active_now:
                    self._supersede(connection, active["decision_id"], now)
                self._replace_ownership(connection, active, row)
            self._refresh_state(connection)
            return {"decision": self._public_decision(row, now)}

    def submit_rule(self, actor, core_id, home_id, body):
        return self._submit(actor, core_id, home_id, body, source="rule")

    def submit_manual(self, actor, core_id, home_id, body):
        return self._submit(actor, core_id, home_id, body, source="manual")

    def complete(self, actor, core_id, home_id, decision_id, body):
        self._scope(core_id, home_id)
        now = self.settings.clock()
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            self._validate(connection)
            decision = self._verified(connection.execute(
                "SELECT * FROM rule_arbiter_decisions WHERE id=?", (decision_id,)
            ).fetchone(), self._decision_tag)
            if (decision["owner_id"], decision["family_id"]) != (actor.id, actor.family_id):
                raise ApiError("not_found", 404)
            if not hmac.compare_digest(body.effectToken, self._effect_token(decision)):
                raise ApiError("rule_arbiter_result_invalid", 400)
            if decision["state"] != "authorized":
                expected = {
                    "applied": ("applied", "adapter_applied", body.readbackDeviceRevision),
                    "rejected": ("rejected", "adapter_rejected", None),
                    "unknown": ("unknown", "adapter_unknown", None),
                }[body.outcome]
                actual = (
                    decision["state"], decision["reason"],
                    decision["readback_device_revision"],
                )
                if actual == expected:
                    return {"decision": self._public_decision(decision, now)}
                raise ApiError("rule_arbiter_result_stale", 409)
            ownership = self._ownership(connection, decision["device_id"])
            if (
                now >= decision["expires_at"]
                or ownership is None
                or ownership["decision_id"] != decision["id"]
                or now >= ownership["expires_at"]
                or (
                    body.outcome == "applied"
                    and body.readbackDeviceRevision <= decision["expected_device_revision"]
                )
            ):
                raise ApiError("rule_arbiter_result_stale", 409)
            result_state, reason = {
                "applied": ("applied", "adapter_applied"),
                "rejected": ("rejected", "adapter_rejected"),
                "unknown": ("unknown", "adapter_unknown"),
            }[body.outcome]
            row = dict(decision)
            row.update(
                revision=row["revision"] + 1, state=result_state, reason=reason,
                completed_at=now, readback_device_revision=body.readbackDeviceRevision,
            )
            row["envelope_tag"] = self._decision_tag(row)
            connection.execute(
                "UPDATE rule_arbiter_decisions SET revision=?,state=?,reason=?,completed_at=?,"
                "readback_device_revision=?,envelope_tag=? WHERE id=?",
                (row["revision"], row["state"], row["reason"], row["completed_at"],
                 row["readback_device_revision"], row["envelope_tag"], row["id"]),
            )
            if body.outcome != "applied":
                connection.execute(
                    "DELETE FROM rule_arbiter_ownership WHERE decision_id=?", (row["id"],)
                )
            self._refresh_state(connection)
            return {"decision": self._public_decision(row, now)}

    def observe_external(self, actor, core_id, home_id, body):
        self._scope(core_id, home_id)
        now = self.settings.clock()
        if body.observedAt > now + 5 or now - body.observedAt > 300:
            raise ApiError("rule_arbiter_observation_stale", 409)
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            self._validate(connection)
            existing = connection.execute(
                "SELECT * FROM rule_arbiter_observations WHERE id=?", (body.observationId,)
            ).fetchone()
            expected = (
                actor.id, actor.family_id, body.deviceId, body.providerRevision,
                body.action, body.observedAt,
            )
            if existing is not None:
                existing = self._verified(existing, self._observation_tag)
                if tuple(existing[name] for name in (
                    "reporter_id", "family_id", "device_id", "provider_revision",
                    "action", "observed_at",
                )) != expected:
                    raise ApiError("idempotency_conflict", 409)
                return {"observation": self._public_observation(existing)}
            if connection.execute(
                "SELECT COUNT(*) FROM rule_arbiter_observations"
            ).fetchone()[0] >= schema.MAX_OBSERVATIONS:
                raise ApiError("rule_arbiter_limit_reached", 429)
            ownership = self._ownership(connection, body.deviceId)
            matches = bool(
                ownership is not None
                and now < ownership["expires_at"]
                and ownership["action"] == body.action
            )
            row = {
                "id": body.observationId, "reporter_id": actor.id,
                "family_id": actor.family_id, "device_id": body.deviceId,
                "provider_revision": body.providerRevision, "action": body.action,
                "observed_at": body.observedAt, "recorded_at": now,
                "matches_decision": int(matches), "control_mode": "observed_only",
            }
            row["envelope_tag"] = self._observation_tag(row)
            connection.execute(
                "INSERT INTO rule_arbiter_observations VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                tuple(row.values()),
            )
            self._refresh_state(connection)
            return {"observation": self._public_observation(row)}

    @staticmethod
    def _public_observation(row):
        return {
            "schemaVersion": 1, "id": row["id"], "deviceId": row["device_id"],
            "providerRevision": row["provider_revision"], "action": row["action"],
            "observedAt": row["observed_at"], "recordedAt": row["recorded_at"],
            "matchesActiveDecision": bool(row["matches_decision"]),
            "controlMode": "observed_only", "authoritative": False,
        }

    def snapshot(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        now = self.settings.clock()
        with self.db.connection() as connection:
            self._actor(connection, actor)
            self._validate(connection)
            ownership = [self._verified(row, self._ownership_tag) for row in connection.execute(
                "SELECT * FROM rule_arbiter_ownership ORDER BY device_id LIMIT ?",
                (schema.MAX_DEVICES,),
            ) if now < row["expires_at"]]
            observations = [
                self._verified(row, self._observation_tag)
                for row in connection.execute(
                    "SELECT * FROM rule_arbiter_observations "
                    "ORDER BY recorded_at DESC,id DESC LIMIT 100"
                )
            ]
        return {
            "schemaVersion": 1, "scope": self.scope.model_dump(),
            "activeOwnership": [{
                "deviceId": row["device_id"], "revision": row["revision"],
                "decisionId": row["decision_id"], "source": row["source"],
                "ruleId": row["rule_id"], "ownerId": row["owner_id"],
                "priority": row["priority"], "action": row["action"],
                "expiresAt": row["expires_at"],
            } for row in ownership],
            "externalObservations": [self._public_observation(row) for row in observations],
            "externalWritesAreObservedOnly": True,
        }
