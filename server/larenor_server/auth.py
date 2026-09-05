from dataclasses import dataclass, field
import hashlib
import hmac
import secrets
import sqlite3
import threading
import uuid

from argon2 import PasswordHasher, Type
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

from .config import Settings
from .database import Database
from .errors import ApiError


def token_hash(value: str) -> str:
    return hashlib.sha256(value.encode("ascii")).hexdigest()


@dataclass(frozen=True)
class Principal:
    id: str
    username: str
    role: str
    must_change_password: bool
    family_id: str
    token_id: str = field(repr=False)

    def public_user(self) -> dict:
        return {"id": self.id, "username": self.username, "role": self.role,
                "mustChangePassword": self.must_change_password}


class AuthService:
    def __init__(self, db: Database, settings: Settings, key: bytes):
        self.db, self.settings, self._key = db, settings, key
        # RFC 9106 low-memory Argon2id profile; never inherited from a moving default.
        self.hasher = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=4,
                                     hash_len=32, salt_len=16, type=Type.ID)
        self._dummy_hash = self.hasher.hash(secrets.token_urlsafe(32))
        self._password_slots = threading.BoundedSemaphore(2)

    def _verify(self, encoded: str, password: str) -> bool:
        if not self._password_slots.acquire(blocking=False):
            raise ApiError("rate_limited", 429)
        try:
            try:
                return self.hasher.verify(encoded, password)
            except (VerifyMismatchError, VerificationError, InvalidHashError):
                return False
        finally:
            self._password_slots.release()

    def hash_password(self, password: str) -> str:
        if not self._password_slots.acquire(blocking=False):
            raise ApiError("rate_limited", 429)
        try:
            return self.hasher.hash(password)
        finally:
            self._password_slots.release()

    def rate_limit(self, categories: list[tuple[str, str, int]], *, seconds: int = 60) -> None:
        now = self.settings.clock()
        window = int(now // seconds)
        denied = False
        with self.db.transaction() as connection:
            connection.execute("DELETE FROM rate_limits WHERE touched_at < ?", (now - 3600,))
            for category, identifier, limit in categories:
                digest = hmac.new(self._key, f"rate:{category}:{identifier}".encode(), hashlib.sha256).hexdigest()
                old = connection.execute("SELECT window, count FROM rate_limits WHERE key=?", (digest,)).fetchone()
                count = old["count"] + 1 if old and old["window"] == window else 1
                connection.execute("INSERT INTO rate_limits VALUES(?,?,?,?) ON CONFLICT(key) DO UPDATE SET "
                                   "window=excluded.window,count=excluded.count,touched_at=excluded.touched_at",
                                   (digest, window, count, now))
                denied |= count > limit
            # Unknown names/addresses cannot grow the database without bound.
            connection.execute("DELETE FROM rate_limits WHERE key IN (SELECT key FROM rate_limits "
                               "ORDER BY touched_at DESC LIMIT -1 OFFSET 10000)")
        if denied:
            raise ApiError("rate_limited", 429)

    def login(self, username: str, password: str, device_name: str, peer: str) -> dict:
        username = username.lower()
        self.rate_limit([
            ("login_ip", peer, self.settings.login_ip_limit),
            ("login_account", username, self.settings.login_account_limit),
            ("login_global", "all", self.settings.login_global_limit),
        ])
        with self.db.connection() as connection:
            user = connection.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
        old_hash = user["password_hash"] if user else self._dummy_hash
        verified = self._verify(old_hash, password)
        if not user or not verified or user["disabled"]:
            raise ApiError("invalid_credentials", 401)
        replacement_hash = self.hash_password(password) if self.hasher.check_needs_rehash(old_hash) else None
        with self.db.transaction() as connection:
            # Password change during the expensive hash must not create an old-credential session.
            current = connection.execute("SELECT * FROM users WHERE id=?", (user["id"],)).fetchone()
            if not current or current["disabled"] or not hmac.compare_digest(current["password_hash"], old_hash):
                raise ApiError("invalid_credentials", 401)
            if replacement_hash:
                connection.execute("UPDATE users SET password_hash=? WHERE id=?", (replacement_hash, current["id"]))
            return self._new_family(connection, current, device_name)

    def _new_family(self, connection: sqlite3.Connection, user: sqlite3.Row, device: str) -> dict:
        now = self.settings.clock()
        # Bound retained device sessions, including inactive records.
        families = connection.execute("SELECT id FROM session_families WHERE user_id=? "
                                      "ORDER BY created_at DESC", (user["id"],)).fetchall()
        for family in families[31:]:
            connection.execute("DELETE FROM session_tokens WHERE family_id=?", (family["id"],))
            connection.execute("DELETE FROM session_families WHERE id=?", (family["id"],))
        family_id = uuid.uuid4().hex
        expires_at = now + self.settings.refresh_ttl_seconds
        connection.execute("INSERT INTO session_families VALUES(?,?,?,?,?,NULL)",
                           (family_id, user["id"], device, now, expires_at))
        return self._issue(connection, user, family_id, expires_at)

    def _issue(self, connection, user, family_id, expires_at) -> dict:
        now = self.settings.clock()
        access, refresh = secrets.token_urlsafe(32), secrets.token_urlsafe(48)
        ttl = max(1, int(min(self.settings.access_ttl_seconds, expires_at - now)))
        connection.execute("INSERT INTO session_tokens VALUES(?,?,?,?,?,?,?,NULL)",
                           (uuid.uuid4().hex, family_id, token_hash(access), token_hash(refresh),
                            now + ttl, expires_at, now))
        return {"accessToken": access, "refreshToken": refresh, "expiresIn": ttl,
                "user": {"id": user["id"], "username": user["username"], "role": user["role"],
                         "mustChangePassword": bool(user["must_change_password"])}}

    @staticmethod
    def _lookup(connection, digest: str, column: str):
        # column is selected only by packaged code, never a request value.
        if column not in ("access_hash", "refresh_hash"):
            raise ValueError("Invalid internal token lookup")
        return connection.execute(
            f"SELECT t.*,f.user_id,f.device_name,f.revoked_at,f.expires_at AS family_expires,"
            f"u.username,u.role,u.must_change_password,u.password_hash,u.disabled FROM session_tokens t "
            f"JOIN session_families f ON f.id=t.family_id JOIN users u ON u.id=f.user_id WHERE t.{column}=?",
            (digest,),
        ).fetchone()

    def authenticate(self, access: str) -> Principal:
        try:
            digest = token_hash(access)
        except (UnicodeError, AttributeError):
            raise ApiError("invalid_session", 401) from None
        with self.db.connection() as connection:
            row = self._lookup(connection, digest, "access_hash")
        now = self.settings.clock()
        if (not row or row["disabled"] or row["revoked_at"] is not None or row["rotated_at"] is not None or
                now >= row["access_expires_at"] or now >= row["family_expires"]):
            raise ApiError("invalid_session", 401)
        return Principal(row["user_id"], row["username"], row["role"],
                         bool(row["must_change_password"]), row["family_id"], row["id"])

    def assert_current(self, connection: sqlite3.Connection, principal: Principal) -> None:
        row = connection.execute(
            "SELECT t.access_expires_at,t.rotated_at,f.revoked_at,f.expires_at,u.role,u.must_change_password,u.disabled "
            "FROM session_tokens t JOIN session_families f ON f.id=t.family_id "
            "JOIN users u ON u.id=f.user_id WHERE t.id=? AND f.id=? AND f.user_id=?",
            (principal.token_id, principal.family_id, principal.id),
        ).fetchone()
        now = self.settings.clock()
        if (not row or row["disabled"] or row["rotated_at"] is not None or row["revoked_at"] is not None or
                now >= row["access_expires_at"] or now >= row["expires_at"] or
                row["role"] != principal.role or bool(row["must_change_password"]) != principal.must_change_password):
            raise ApiError("invalid_session", 401)

    def refresh(self, refresh: str, peer: str) -> dict:
        self.rate_limit([("refresh_ip", peer, 30)])
        digest = token_hash(refresh)
        invalid = False
        result = None
        with self.db.transaction() as connection:
            row = self._lookup(connection, digest, "refresh_hash")
            now = self.settings.clock()
            if not row or row["disabled"] or row["revoked_at"] is not None:
                invalid = True
            elif row["rotated_at"] is not None:
                # A consumed refresh token remains as replay evidence until family expiry.
                connection.execute("UPDATE session_families SET revoked_at=? WHERE id=?", (now, row["family_id"]))
                invalid = True
            elif now >= row["refresh_expires_at"] or now >= row["family_expires"]:
                connection.execute("UPDATE session_families SET revoked_at=? WHERE id=?", (now, row["family_id"]))
                invalid = True
            elif row["must_change_password"]:
                raise ApiError("password_change_required", 403)
            elif connection.execute("SELECT COUNT(*) FROM session_tokens WHERE family_id=?",
                                    (row["family_id"],)).fetchone()[0] >= 4096:
                connection.execute("UPDATE session_families SET revoked_at=? WHERE id=?", (now, row["family_id"]))
                invalid = True
            else:
                connection.execute("UPDATE session_tokens SET rotated_at=? WHERE id=?", (now, row["id"]))
                user = connection.execute("SELECT * FROM users WHERE id=?", (row["user_id"],)).fetchone()
                result = self._issue(connection, user, row["family_id"], row["family_expires"])
        # Do not roll back replay revocation by raising from inside the transaction.
        if invalid:
            raise ApiError("invalid_session", 401)
        return result

    def logout(self, principal: Principal, refresh: str | None = None) -> None:
        # Optional refresh never grants authority over another device or another user.
        with self.db.transaction() as connection:
            self.assert_current(connection, principal)
            connection.execute("UPDATE session_families SET revoked_at=? WHERE id=? AND user_id=?",
                               (self.settings.clock(), principal.family_id, principal.id))

    def change_password(self, principal: Principal, current_password: str, new_password: str) -> dict:
        self.rate_limit([("password_change", principal.id, 5)])
        with self.db.connection() as connection:
            user = connection.execute("SELECT * FROM users WHERE id=?", (principal.id,)).fetchone()
        if not user or not self._verify(user["password_hash"], current_password):
            raise ApiError("invalid_credentials", 401)
        if current_password == new_password:
            raise ApiError("password_unchanged", 400)
        encoded = self.hash_password(new_password)
        with self.db.transaction() as connection:
            self.assert_current(connection, principal)
            now = self.settings.clock()
            current = connection.execute("SELECT * FROM users WHERE id=?", (principal.id,)).fetchone()
            family = connection.execute("SELECT * FROM session_families WHERE id=?", (principal.family_id,)).fetchone()
            if (not current or not hmac.compare_digest(current["password_hash"], user["password_hash"]) or
                    not family or family["revoked_at"] is not None or now >= family["expires_at"]):
                raise ApiError("invalid_session", 401)
            connection.execute("UPDATE users SET password_hash=?,must_change_password=0,revision=revision+1 WHERE id=?", (encoded, principal.id))
            connection.execute("UPDATE session_families SET revoked_at=? WHERE user_id=?", (now, principal.id))
            updated = connection.execute("SELECT * FROM users WHERE id=?", (principal.id,)).fetchone()
            return self._new_family(connection, updated, family["device_name"])
