from collections.abc import Iterator
from contextlib import contextmanager
from datetime import datetime, timezone
import sqlite3
import uuid

from ..auth import AuthService, Principal
from ..config import Settings
from ..database import Database
from ..errors import ApiError
from .models import CreateUserRequest, ResetPasswordRequest, UpdateUserRequest


MAX_USERS = 256
MAX_AUDIT_EVENTS = 10000


def utc(value: float) -> str:
    return datetime.fromtimestamp(value, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def public_user(row: sqlite3.Row) -> dict:
    return {"id": row["id"], "username": row["username"], "role": row["role"],
            "disabled": bool(row["disabled"]), "mustChangePassword": bool(row["must_change_password"]),
            "revision": row["revision"], "createdAt": utc(row["created_at"])}


class AdminService:
    def __init__(self, db: Database, auth: AuthService, settings: Settings):
        self.db, self.auth, self.settings = db, auth, settings

    def _assert_admin(self, connection: sqlite3.Connection, actor: Principal) -> None:
        # Recheck inside the transaction: HTTP dependencies are only an early gate.
        self.auth.assert_current(connection, actor)
        if actor.must_change_password:
            raise ApiError("password_change_required", 403)
        if actor.role != "admin":
            raise ApiError("forbidden", 403)

    @contextmanager
    def _read(self, actor: Principal) -> Iterator[sqlite3.Connection]:
        self.auth.rate_limit([("admin_read", actor.id, 120)])
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            yield connection

    @contextmanager
    def _mutation(self, actor: Principal, action: str, target_id: str | None) -> Iterator[sqlite3.Connection]:
        events = {"create": ("admin.user.created", "user"),
                  "update": ("admin.user.updated", "user"),
                  "reset_password": ("admin.user.password_reset", "user"),
                  "revoke": ("admin.session.revoked", "session")}
        event, object_type = events[action]
        error = None
        with self.db.transaction() as connection:
            self._assert_admin(connection, actor)
            # Retain only a static denied outcome, never a partially applied write.
            connection.execute("SAVEPOINT admin_action")
            try:
                yield connection
            except ApiError as caught:
                connection.execute("ROLLBACK TO admin_action")
                error = caught
            connection.execute("RELEASE admin_action")
            connection.execute("INSERT INTO admin_audit(event,action,object,status,timestamp,actor_id,target_id) "
                               "VALUES(?,?,?,?,?,?,?)", (event, action, object_type,
                               "denied" if error else "success", self.settings.clock(), actor.id, target_id))
            connection.execute("DELETE FROM admin_audit WHERE id IN (SELECT id FROM admin_audit "
                               "ORDER BY id DESC LIMIT -1 OFFSET ?)", (MAX_AUDIT_EVENTS,))
        if error:
            raise error

    def _write_limit(self, actor: Principal) -> None:
        self.auth.rate_limit([("admin_write", actor.id, 20)])

    @staticmethod
    def _user(connection: sqlite3.Connection, user_id: str, revision: int | None = None):
        row = connection.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
        if not row:
            raise ApiError("not_found", 404)
        if revision is not None and row["revision"] != revision:
            raise ApiError("revision_conflict", 409)
        return row

    def users(self, actor: Principal) -> dict:
        with self._read(actor) as connection:
            rows = connection.execute("SELECT * FROM users ORDER BY username,id LIMIT ?", (MAX_USERS,)).fetchall()
            return {"users": [public_user(row) for row in rows]}

    def create_user(self, actor: Principal, body: CreateUserRequest) -> dict:
        self._write_limit(actor)
        encoded = self.auth.hash_password(body.initialPassword)
        user_id = uuid.uuid4().hex
        with self._mutation(actor, "create", user_id) as connection:
            if connection.execute("SELECT COUNT(*) FROM users").fetchone()[0] >= MAX_USERS:
                raise ApiError("user_limit_reached", 409)
            if connection.execute("SELECT id FROM users WHERE username=?", (body.username.lower(),)).fetchone():
                raise ApiError("username_unavailable", 409)
            connection.execute("INSERT INTO users(id,username,role,password_hash,must_change_password,created_at) "
                               "VALUES(?,?,?,?,1,?)", (user_id, body.username.lower(), body.role, encoded, self.settings.clock()))
            result = public_user(self._user(connection, user_id))
        return {"user": result}

    def update_user(self, actor: Principal, user_id: str, body: UpdateUserRequest) -> dict:
        self._write_limit(actor)
        with self._mutation(actor, "update", user_id) as connection:
            row = self._user(connection, user_id, body.expectedRevision)
            role = body.role if body.role is not None else row["role"]
            disabled = body.disabled if body.disabled is not None else bool(row["disabled"])
            if row["role"] == "admin" and not row["disabled"] and (role != "admin" or disabled):
                remaining = connection.execute("SELECT COUNT(*) FROM users WHERE role='admin' AND disabled=0").fetchone()[0]
                if remaining <= 1:
                    raise ApiError("last_active_admin", 409)
            if role != row["role"] or disabled != bool(row["disabled"]):
                connection.execute("UPDATE users SET role=?,disabled=?,revision=revision+1 WHERE id=?",
                                   (role, int(disabled), user_id))
                self._revoke_user(connection, user_id)
            result = public_user(self._user(connection, user_id))
        return {"user": result}

    def reset_password(self, actor: Principal, user_id: str, body: ResetPasswordRequest) -> dict:
        self._write_limit(actor)
        if actor.id == user_id:
            # Deliberately no self-reset shortcut around current-password verification.
            with self._mutation(actor, "reset_password", user_id):
                raise ApiError("self_password_reset_forbidden", 403)
        encoded = self.auth.hash_password(body.temporaryPassword)
        with self._mutation(actor, "reset_password", user_id) as connection:
            self._user(connection, user_id, body.expectedRevision)
            connection.execute("UPDATE users SET password_hash=?,must_change_password=1,revision=revision+1 WHERE id=?",
                               (encoded, user_id))
            self._revoke_user(connection, user_id)
            result = public_user(self._user(connection, user_id))
        return {"user": result}

    def _revoke_user(self, connection: sqlite3.Connection, user_id: str) -> None:
        connection.execute("UPDATE session_families SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL",
                           (self.settings.clock(), user_id))

    def sessions(self, actor: Principal, *, user_id: str | None = None, cursor: str | None = None, limit: int = 50) -> dict:
        with self._read(actor) as connection:
            parameters = []
            predicates = []
            if user_id:
                self._user(connection, user_id)
                predicates.append("user_id=?")
                parameters.append(user_id)
            if cursor:
                anchor = connection.execute("SELECT created_at,user_id FROM session_families WHERE id=?", (cursor,)).fetchone()
                if not anchor or (user_id and anchor["user_id"] != user_id):
                    raise ApiError("invalid_request", 400)
                predicates.append("(created_at < ? OR (created_at = ? AND id < ?))")
                parameters.extend([anchor["created_at"], anchor["created_at"], cursor])
            where = " WHERE " + " AND ".join(predicates) if predicates else ""
            rows = connection.execute("SELECT * FROM session_families" + where +
                                      " ORDER BY created_at DESC,id DESC LIMIT ?", (*parameters, limit + 1)).fetchall()
            now = self.settings.clock()
            return {"sessions": [{"id": row["id"], "userId": row["user_id"], "deviceName": row["device_name"],
                                  "createdAt": utc(row["created_at"]), "expiresAt": utc(row["expires_at"]),
                                  "revokedAt": utc(row["revoked_at"]) if row["revoked_at"] is not None else None,
                                  "status": "revoked" if row["revoked_at"] is not None else
                                  "expired" if now >= row["expires_at"] else "active"} for row in rows[:limit]],
                    "nextCursor": rows[limit - 1]["id"] if len(rows) > limit else None}

    def revoke_session(self, actor: Principal, family_id: str) -> None:
        self._write_limit(actor)
        with self._mutation(actor, "revoke", family_id) as connection:
            row = connection.execute("SELECT id FROM session_families WHERE id=?", (family_id,)).fetchone()
            if not row:
                raise ApiError("not_found", 404)
            connection.execute("UPDATE session_families SET revoked_at=? WHERE id=? AND revoked_at IS NULL",
                               (self.settings.clock(), family_id))

    def audit(self, actor: Principal, *, cursor: int | None = None, limit: int = 50) -> dict:
        with self._read(actor) as connection:
            rows = connection.execute("SELECT * FROM admin_audit WHERE id < ? ORDER BY id DESC LIMIT ?",
                                      (cursor if cursor is not None else 2**63 - 1, limit + 1)).fetchall()
            return {"events": [{"id": str(row["id"]), "event": row["event"], "action": row["action"],
                                "object": row["object"], "status": row["status"], "timestamp": utc(row["timestamp"]),
                                "actorId": row["actor_id"], "targetId": row["target_id"]} for row in rows[:limit]],
                    "nextCursor": str(rows[limit - 1]["id"]) if len(rows) > limit else None}
