import hashlib
import hmac
import json
import math
import sqlite3
import uuid

from ..errors import ApiError, StartupError
from ..home_assistant.rule_models import RuleCreateRequest
from .models import ActivateAutomationDraft, CreateAutomationDraft


MAX_DRAFTS = 256
DRAFT_TTL_SECONDS = 15 * 60
TERMINAL_REPLAY_SECONDS = 24 * 60 * 60
CATALOG_VERSION = "ha-switch-actions-v1"
PHRASES = {
    "aç": "turn_on",
    "ışığı aç": "turn_on",
    "anahtarı aç": "turn_on",
    "turn on": "turn_on",
    "switch on": "turn_on",
    "kapat": "turn_off",
    "ışığı kapat": "turn_off",
    "anahtarı kapat": "turn_off",
    "turn off": "turn_off",
    "switch off": "turn_off",
}


class AutomationDraftService:
    def __init__(self, rules, settings, key):
        self.rules, self.settings = rules, settings
        self.db, self.auth = rules.adapter.db, rules.adapter.auth
        self._key = hmac.new(key, b"larenor-automation-drafts-v1", hashlib.sha256).digest()

    def _tag(self, row):
        values = [row[name] for name in (
            "id", "owner_id", "family_id", "request_key", "transcript_hash",
            "resource_id", "action", "resource_revision", "acl_revision",
            "binding_revision", "service_revision", "revision", "state", "rule_id",
            "created_at", "expires_at",
        )]
        return hmac.new(
            self._key,
            json.dumps(values, separators=(",", ":"), ensure_ascii=True).encode("ascii"),
            hashlib.sha256,
        ).hexdigest()

    def _verified(self, row):
        if row is None:
            raise ApiError("not_found", 404)
        if not hmac.compare_digest(row["record_tag"], self._tag(row)):
            raise StartupError("automation_draft_storage_invalid")
        return row

    def _validate(self, connection):
        rows = connection.execute(
            "SELECT * FROM automation_drafts ORDER BY id LIMIT ?", (MAX_DRAFTS + 1,)
        ).fetchall()
        if len(rows) > MAX_DRAFTS:
            raise StartupError("automation_draft_storage_invalid")
        for row in rows:
            self._verified(row)
            if (
                not math.isfinite(row["created_at"])
                or not math.isfinite(row["expires_at"])
                or row["created_at"] < 0
                or row["expires_at"] != row["created_at"] + DRAFT_TTL_SECONDS
                or (row["state"] == "activated") != (row["rule_id"] is not None)
            ):
                raise StartupError("automation_draft_storage_invalid")
        return rows

    def _ensure_capacity(self, connection, now):
        # Authenticate the complete bounded history before the first deletion.
        # Activated drafts are receipts; their separately stored rules survive.
        rows = self._validate(connection)
        if any(row["created_at"] > now for row in rows):
            raise ApiError("automation_draft_clock_invalid", 503)
        if len(rows) < MAX_DRAFTS:
            return
        cutoff = now - TERMINAL_REPLAY_SECONDS
        for row in rows:
            if row["expires_at"] < cutoff:
                connection.execute("DELETE FROM automation_drafts WHERE id=?", (row["id"],))
        if connection.execute("SELECT COUNT(*) FROM automation_drafts").fetchone()[0] >= MAX_DRAFTS:
            raise ApiError("automation_draft_limit_reached", 429)

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                self._validate(connection)
        except StartupError:
            raise
        except (sqlite3.Error, TypeError, ValueError):
            raise StartupError("automation_draft_storage_invalid") from None

    @staticmethod
    def _action(transcript):
        action = PHRASES.get(transcript.translate(str.maketrans({"I": "ı", "İ": "i"})).casefold())
        if action is None:
            raise ApiError("automation_draft_transcript_unsupported", 400)
        return action

    def _public(self, row, now, rule=None):
        return {
            "schemaVersion": 1,
            "id": row["id"],
            "revision": row["revision"],
            "state": row["state"],
            "catalogVersion": CATALOG_VERSION,
            "target": {"resourceId": row["resource_id"]},
            "action": row["action"],
            "steps": ["validate_current_target", "create_inert_rule"],
            "sideEffects": ["creates_automation_rule", "does_not_execute_device"],
            "expiresAt": row["expires_at"],
            "expired": now >= row["expires_at"],
            "requiresExplicitConfirmation": row["state"] == "draft",
            "deviceCommandAvailable": False,
            "rule": None if rule is None else rule.model_dump(mode="json"),
        }

    def create(self, actor, core, home, body):
        body = CreateAutomationDraft.model_validate(body)
        action = self._action(body.transcript)
        digest = hashlib.sha256(body.transcript.encode("utf-8")).hexdigest()
        now = float(self.settings.clock())
        if not math.isfinite(now) or now < 0:
            raise ApiError("automation_draft_clock_invalid", 503)
        with self.rules.adapter._tx(actor, core, home, admin=True) as (connection, facts):
            self._validate(connection)
            existing = connection.execute(
                "SELECT * FROM automation_drafts WHERE owner_id=? AND family_id=? AND request_key=?",
                (actor.id, actor.family_id, body.requestKey),
            ).fetchone()
            if existing is not None:
                existing = self._verified(existing)
                expected = (
                    digest, body.resourceId, action, body.expectedResourceRevision,
                    body.expectedAclRevision, body.expectedBindingRevision,
                    body.expectedServiceRevision,
                )
                actual = tuple(existing[name] for name in (
                    "transcript_hash", "resource_id", "action", "resource_revision",
                    "acl_revision", "binding_revision", "service_revision",
                ))
                if actual != expected:
                    raise ApiError("idempotency_conflict", 409)
                return {"draft": self._public(existing, now)}
            self._ensure_capacity(connection, now)
            target, ref, data, binding = self.rules._current_target(connection, facts, body.resourceId)
            self.rules.adapter.resources._require(
                facts, target, ref, data, "write",
                expected_revision=body.expectedResourceRevision,
                expected_acl_revision=body.expectedAclRevision,
            )
            if (
                binding is None
                or binding.revision != body.expectedBindingRevision
                or binding.serviceRevision != body.expectedServiceRevision
            ):
                raise ApiError("ha_rule_changed", 409)
            row = {
                "id": uuid.uuid4().hex, "owner_id": actor.id,
                "family_id": actor.family_id, "request_key": body.requestKey,
                "transcript_hash": digest, "resource_id": body.resourceId,
                "action": action, "resource_revision": body.expectedResourceRevision,
                "acl_revision": body.expectedAclRevision,
                "binding_revision": body.expectedBindingRevision,
                "service_revision": body.expectedServiceRevision,
                "revision": 1, "state": "draft", "rule_id": None,
                "created_at": now, "expires_at": now + DRAFT_TTL_SECONDS,
            }
            connection.execute(
                "INSERT INTO automation_drafts VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (*row.values(), self._tag(row)),
            )
            return {"draft": self._public(self._verified(connection.execute(
                "SELECT * FROM automation_drafts WHERE id=?", (row["id"],)
            ).fetchone()), now)}

    def activate(self, actor, core, home, draft_id, body):
        body = ActivateAutomationDraft.model_validate(body)
        now = float(self.settings.clock())
        with self.rules.adapter._tx(actor, core, home, admin=True) as (connection, facts):
            self._validate(connection)
            row = self._verified(connection.execute(
                "SELECT * FROM automation_drafts WHERE id=? AND owner_id=? AND family_id=?",
                (draft_id, actor.id, actor.family_id),
            ).fetchone())
            if row["state"] == "activated":
                rule = self.rules._stored(connection, row["rule_id"], row["resource_id"])
                return {"draft": self._public(row, now, rule)}
            if row["revision"] != body.expectedDraftRevision:
                raise ApiError("automation_draft_changed", 409)
            if now >= row["expires_at"]:
                raise ApiError("automation_draft_expired", 409)
            rule = self.rules.create_in_transaction(
                connection, facts, actor, row["resource_id"],
                RuleCreateRequest(
                    action=row["action"],
                    expectedResourceRevision=row["resource_revision"],
                    expectedAclRevision=row["acl_revision"],
                    expectedBindingRevision=row["binding_revision"],
                    expectedServiceRevision=row["service_revision"],
                ),
            )
            updated = dict(row)
            updated.update(revision=row["revision"] + 1, state="activated", rule_id=rule.id)
            updated["record_tag"] = self._tag(updated)
            connection.execute(
                "UPDATE automation_drafts SET revision=?,state=?,rule_id=?,record_tag=? WHERE id=?",
                (updated["revision"], updated["state"], updated["rule_id"], updated["record_tag"], draft_id),
            )
            return {"draft": self._public(updated, now, rule)}
