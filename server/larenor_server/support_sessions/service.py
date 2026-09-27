import base64
import hashlib
import hmac
import json
import secrets
import sqlite3
import uuid

from ..component_egress import storage as egress_storage
from ..core_audit.journal import append_home_resource, checkpoint
from ..errors import ApiError, StartupError
from . import schema
from .models import CreateSupportSession, RevokeSupportSession, SupportAccess


MAX_LIFETIME_SECONDS = 20 * 60
PERMISSIONS = {
    "core:health.read",
    "core:audit.verify",
    "home_registry:resource_count.read",
    "component_egress:summary.read",
    "session:activity.read",
}
REDACTED_FIELDS = [
    "authorization",
    "cookies",
    "credentials",
    "requestBody",
    "responseBody",
    "freeformLogs",
]


class SupportSessionService:
    def __init__(self, resources, component_egress, settings, key):
        self.resources, self.component_egress, self.settings = resources, component_egress, settings
        self.db, self.auth = resources.db, resources.auth
        self._audit_key = key
        self._key = hmac.new(key, b"larenor-support-sessions-v1", hashlib.sha256).digest()

    def _tag(self, kind, row, fields):
        payload = json.dumps([row[field] for field in fields], separators=(",", ":"), ensure_ascii=True)
        return hmac.new(self._key, kind + b"\0" + payload.encode("ascii"), hashlib.sha256).hexdigest()

    def _session_tag(self, row):
        return self._tag(b"session", row, (
            "id", "owner_id", "family_id", "core_id", "home_id", "request_key",
            "supporter_id", "supporter_name",
            "permissions_json", "token_hash", "revision", "state", "expires_at", "created_at", "updated_at",
        ))

    def _event_tag(self, row):
        return self._tag(b"event", row, ("id", "session_id", "permission", "outcome", "created_at"))

    def _verified_session(self, row):
        if row is None:
            raise ApiError("not_found", 404)
        try:
            permissions = json.loads(row["permissions_json"])
        except (TypeError, json.JSONDecodeError):
            raise StartupError("support_session_storage_invalid") from None
        if (
            permissions != sorted(set(permissions))
            or not permissions
            or any(permission not in PERMISSIONS for permission in permissions)
            or not hmac.compare_digest(row["record_tag"], self._session_tag(row))
        ):
            raise StartupError("support_session_storage_invalid")
        return row, permissions

    def _verified_event(self, row):
        if row is None or not hmac.compare_digest(row["record_tag"], self._event_tag(row)):
            raise StartupError("support_session_storage_invalid")
        return row

    def _validate(self, connection):
        sessions = connection.execute(
            "SELECT * FROM support_sessions ORDER BY id LIMIT ?", (schema.MAX_SESSIONS + 1,)
        ).fetchall()
        events = connection.execute(
            "SELECT * FROM support_session_events ORDER BY created_at,id LIMIT ?", (schema.MAX_EVENTS + 1,)
        ).fetchall()
        if len(sessions) > schema.MAX_SESSIONS or len(events) > schema.MAX_EVENTS:
            raise StartupError("support_session_storage_invalid")
        for row in sessions:
            self._verified_session(row)
        for row in events:
            self._verified_event(row)
        return sessions, events

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                self._validate(connection)
        except StartupError:
            raise
        except (sqlite3.Error, TypeError, ValueError):
            raise StartupError("support_session_storage_invalid") from None

    def _public(self, row, permissions):
        state = row["state"]
        now = float(self.settings.clock())
        if state == "active" and now >= row["expires_at"]:
            state = "expired"
        return {
            "schemaVersion": 1,
            "id": row["id"],
            "revision": row["revision"],
            "supporterId": row["supporter_id"],
            "supporterName": row["supporter_name"],
            "permissions": permissions,
            "state": state,
            "expiresAt": row["expires_at"],
            "remainingSeconds": max(0, int(row["expires_at"] - now)) if state == "active" else 0,
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
            "logPolicy": {"freeformLogsStored": False, "redactedFields": REDACTED_FIELDS},
        }

    def _events(self, connection, session_id):
        rows = connection.execute(
            "SELECT * FROM support_session_events WHERE session_id=? ORDER BY created_at DESC,id DESC LIMIT 50",
            (session_id,),
        ).fetchall()
        return [
            {
                "schemaVersion": 1,
                "id": self._verified_event(row)["id"],
                "permission": row["permission"],
                "outcome": row["outcome"],
                "createdAt": row["created_at"],
                "detailsStored": False,
            }
            for row in rows
        ]

    def list(self, actor, core_id, home_id):
        with self.resources._transaction(actor, core_id, home_id, admin=True) as (connection, _facts):
            self._validate(connection)
            sessions = connection.execute(
                "SELECT * FROM support_sessions WHERE owner_id=? AND core_id=? AND home_id=? "
                "ORDER BY created_at DESC,id DESC",
                (actor.id, core_id, home_id),
            ).fetchall()
            return {
                "schemaVersion": 1,
                "sessions": [self._public(row, json.loads(row["permissions_json"])) for row in sessions],
                "maximumSessions": schema.MAX_SESSIONS,
                "maximumLifetimeSeconds": MAX_LIFETIME_SECONDS,
            }

    def get(self, actor, core_id, home_id, session_id):
        with self.resources._transaction(actor, core_id, home_id, admin=True) as (connection, _facts):
            self._validate(connection)
            row, permissions = self._verified_session(connection.execute(
                "SELECT * FROM support_sessions WHERE id=? AND core_id=? AND home_id=?",
                (session_id, core_id, home_id),
            ).fetchone())
            if row["owner_id"] != actor.id:
                raise ApiError("not_found", 404)
            return {"session": self._public(row, permissions), "activity": self._events(connection, session_id)}

    def create(self, actor, core_id, home_id, value):
        body = CreateSupportSession.model_validate(value)
        now = float(self.settings.clock())
        if not now + 60 <= body.expiresAt <= now + MAX_LIFETIME_SECONDS:
            raise ApiError("invalid_request")
        with self.resources._transaction(actor, core_id, home_id, admin=True) as (connection, _facts):
            sessions, _events = self._validate(connection)
            existing = connection.execute(
                "SELECT * FROM support_sessions WHERE owner_id=? AND family_id=? AND core_id=? "
                "AND home_id=? AND request_key=?",
                (actor.id, actor.family_id, core_id, home_id, body.requestKey),
            ).fetchone()
            if existing is not None:
                row, permissions = self._verified_session(existing)
                if (row["supporter_id"], row["supporter_name"], permissions, row["expires_at"]) != (
                    body.supporterId, body.supporterName, body.permissions, body.expiresAt
                ):
                    raise ApiError("idempotency_conflict", 409)
                raise ApiError("support_session_token_already_issued", 409)
            if len(sessions) >= schema.MAX_SESSIONS:
                raise ApiError("support_session_limit_reached", 429)
            raw = secrets.token_bytes(32)
            token = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
            token_hash = hmac.new(self._key, b"token\0" + raw, hashlib.sha256).hexdigest()
            row = {
                "id": uuid.uuid4().hex,
                "owner_id": actor.id,
                "family_id": actor.family_id,
                "core_id": core_id,
                "home_id": home_id,
                "request_key": body.requestKey,
                "supporter_id": body.supporterId,
                "supporter_name": body.supporterName,
                "permissions_json": json.dumps(body.permissions, separators=(",", ":")),
                "token_hash": token_hash,
                "revision": 1,
                "state": "active",
                "expires_at": body.expiresAt,
                "created_at": now,
                "updated_at": now,
            }
            row["record_tag"] = self._session_tag(row)
            connection.execute(
                "INSERT INTO support_sessions VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                tuple(row.values()),
            )
            append_home_resource(
                connection, self._audit_key, self.resources.scope,
                action="create", status="success", actor_id=actor.id,
                target_id=row["id"], created_at=now,
            )
            return {"session": self._public(row, body.permissions), "accessToken": token}

    def revoke(self, actor, core_id, home_id, session_id, value):
        body = RevokeSupportSession.model_validate(value)
        now = float(self.settings.clock())
        with self.resources._transaction(actor, core_id, home_id, admin=True) as (connection, _facts):
            self._validate(connection)
            row, permissions = self._verified_session(connection.execute(
                "SELECT * FROM support_sessions WHERE id=? AND core_id=? AND home_id=?",
                (session_id, core_id, home_id),
            ).fetchone())
            if row["owner_id"] != actor.id:
                raise ApiError("not_found", 404)
            if row["state"] == "revoked":
                return {"session": self._public(row, permissions)}
            if row["revision"] != body.expectedRevision:
                raise ApiError("support_session_changed", 409)
            updated = dict(row)
            updated.update(revision=row["revision"] + 1, state="revoked", updated_at=now)
            updated["record_tag"] = self._session_tag(updated)
            connection.execute(
                "UPDATE support_sessions SET revision=?,state=?,updated_at=?,record_tag=? WHERE id=?",
                (updated["revision"], updated["state"], updated["updated_at"], updated["record_tag"], session_id),
            )
            append_home_resource(
                connection, self._audit_key, self.resources.scope,
                action="delete", status="success", actor_id=actor.id,
                target_id=session_id, created_at=now,
            )
            return {"session": self._public(updated, permissions)}

    def _token_hash(self, token):
        if not isinstance(token, str) or len(token) != 43:
            raise ApiError("invalid_support_token", 401)
        try:
            raw = base64.urlsafe_b64decode(token + "=")
        except (ValueError, TypeError):
            raise ApiError("invalid_support_token", 401) from None
        if len(raw) != 32 or base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=") != token:
            raise ApiError("invalid_support_token", 401)
        return hmac.new(self._key, b"token\0" + raw, hashlib.sha256).hexdigest()

    def _authority(self, connection, token, supporter_id, core_id, home_id):
        self.resources._check_context(connection, core_id, home_id)
        row = connection.execute(
            "SELECT * FROM support_sessions WHERE token_hash=?", (self._token_hash(token),)
        ).fetchone()
        if row is None:
            raise ApiError("invalid_support_token", 401)
        row, permissions = self._verified_session(row)
        now = float(self.settings.clock())
        family = connection.execute(
            "SELECT * FROM session_families WHERE id=? AND user_id=?", (row["family_id"], row["owner_id"])
        ).fetchone()
        owner = connection.execute("SELECT * FROM users WHERE id=?", (row["owner_id"],)).fetchone()
        if (
            row["state"] != "active"
            or row["core_id"] != core_id
            or row["home_id"] != home_id
            or not hmac.compare_digest(row["supporter_id"], supporter_id)
            or now >= row["expires_at"]
            or family is None
            or family["revoked_at"] is not None
            or now >= family["expires_at"]
            or owner is None
            or owner["disabled"]
            or owner["must_change_password"]
            or owner["role"] != "admin"
        ):
            raise ApiError("support_session_inactive", 401)
        return row, permissions

    def _record_event(self, connection, session, permission, outcome):
        count = connection.execute("SELECT COUNT(*) FROM support_session_events").fetchone()[0]
        if count >= schema.MAX_EVENTS:
            raise ApiError("support_session_event_limit_reached", 429)
        row = {
            "id": uuid.uuid4().hex,
            "session_id": session["id"],
            "permission": permission if permission in PERMISSIONS else "unrecognized",
            "outcome": outcome,
            "created_at": float(self.settings.clock()),
        }
        row["record_tag"] = self._event_tag(row)
        connection.execute("INSERT INTO support_session_events VALUES(?,?,?,?,?,?)", tuple(row.values()))
        append_home_resource(
            connection, self._audit_key, self.resources.scope,
            action="grant", status="success" if outcome == "allowed" else "denied",
            actor_id=session["owner_id"], target_id=session["id"],
            created_at=row["created_at"],
        )

    def access(self, token, supporter_id, core_id, home_id, value):
        body = SupportAccess.model_validate(value)
        self.auth.rate_limit([("support_client", supporter_id, 120), ("support_global", "all", 1000)])
        denied = False
        result = None
        with self.db.transaction() as connection:
            self._validate(connection)
            session, permissions = self._authority(connection, token, supporter_id, core_id, home_id)
            if body.permission not in permissions:
                self._record_event(connection, session, body.permission, "denied")
                denied = True
            else:
                if body.permission == "core:health.read":
                    result = {
                        "status": "ready", "coreId": core_id, "homeId": home_id,
                        "secretsIncluded": False, "remoteShellAvailable": False,
                    }
                elif body.permission == "core:audit.verify":
                    verified = checkpoint(connection, self._audit_key, self.resources.scope, None)
                    result = {
                        "verified": verified["verified"], "sequence": verified["sequence"],
                        "headHash": verified["headHash"], "causalityVerified": verified["causalityVerified"],
                    }
                elif body.permission == "home_registry:resource_count.read":
                    result = {"resourceCount": self.resources._state(connection)["record_count"]}
                elif body.permission == "component_egress:summary.read":
                    state = egress_storage.load(
                        connection, self.component_egress.key, self.component_egress.scope
                    )
                    result = {"policyCount": len(state.policies), "eventCount": len(state.events)}
                else:
                    result = {"activity": self._events(connection, session["id"])}
                self._record_event(connection, session, body.permission, "allowed")
        if denied:
            raise ApiError("support_permission_forbidden", 403)
        return {
            "schemaVersion": 1,
            "permission": body.permission,
            "result": result,
            "logPolicy": {"freeformLogsStored": False, "redactedFields": REDACTED_FIELDS},
        }
