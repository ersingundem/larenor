import hashlib
import hmac
import json
import uuid

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope


MAX_HOSTS = 64
MAX_SESSIONS = 2048
MAX_COMMANDS = 8192
MAX_SESSION_TTL = 3600


class GameStreamAuthorityService:
    """Durable authorization receipts; it never contacts or replays a host effect."""

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings, self._key = db, auth, settings, key
        self.scope = HomeScope.model_validate(context.model_dump())

    def _tag(self, kind, values):
        payload = json.dumps(values, separators=(",", ":"), sort_keys=True).encode("utf-8")
        return hmac.new(self._key, b"larenor-game-stream-v1\0" + kind.encode() + b"\0" + payload,
                        hashlib.sha256).hexdigest()

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    def _actor(self, connection, actor, *, admin=False):
        self.auth.assert_current(connection, actor)
        row = connection.execute("SELECT * FROM users WHERE id=?", (actor.id,)).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("invalid_session", 401)
        if admin and row["role"] != "admin":
            raise ApiError("forbidden", 403)
        return row

    @staticmethod
    def _canonical(model):
        return model.model_dump_json().encode("utf-8")

    def _host_tag(self, row):
        return self._tag("host", {key: row[key] for key in (
            "id", "registration_id", "revision", "name", "pairing_revision",
            "credential_digest", "capabilities", "active", "created_at", "updated_at")})

    def _session_tag(self, row):
        return self._tag("session", {key: row[key] for key in (
            "id", "owner_id", "family_id", "host_id", "revision", "request_key",
            "request_hash", "authority", "expires_at", "state", "created_at")})

    def _command_tag(self, row):
        return self._tag("command", {key: row[key] for key in (
            "id", "session_id", "request_key", "request_hash", "intent", "state",
            "result", "readback_revision", "created_at", "completed_at")})

    def _host(self, row):
        if row is None or not hmac.compare_digest(row["envelope_tag"], self._host_tag(row)):
            raise StartupError("game_stream_storage_invalid")
        return row

    def _session(self, row):
        if row is None or not hmac.compare_digest(row["envelope_tag"], self._session_tag(row)):
            raise StartupError("game_stream_storage_invalid")
        return row

    def _command(self, row):
        if row is None or not hmac.compare_digest(row["envelope_tag"], self._command_tag(row)):
            raise StartupError("game_stream_storage_invalid")
        return row

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                for row in connection.execute("SELECT * FROM game_stream_hosts"):
                    self._host(row)
                for row in connection.execute("SELECT * FROM game_stream_sessions"):
                    self._session(row)
                for row in connection.execute("SELECT * FROM game_stream_commands"):
                    self._command(row)
        except (TypeError, ValueError):
            raise StartupError("game_stream_storage_invalid") from None

    def _public_host(self, row):
        capabilities = json.loads(row["capabilities"])
        return {"schemaVersion": 1, "ref": {**self.scope.model_dump(),
                "kind": "game_stream_host", "id": row["id"]},
                "revision": row["revision"], "name": row["name"],
                "pairingRevision": row["pairing_revision"], "active": bool(row["active"]),
                **capabilities}

    def register(self, actor, core_id, home_id, body):
        self._scope(core_id, home_id)
        self.auth.rate_limit([("game_stream_write", actor.id, 120)])
        now = self.settings.clock()
        with self.db.transaction() as connection:
            self._actor(connection, actor, admin=True)
            prior = connection.execute(
                "SELECT * FROM game_stream_hosts WHERE registration_id=?", (body.registrationId,)
            ).fetchone()
            if prior is not None:
                prior = self._host(prior)
                expected = hmac.new(self._key, body.credentialHandle.encode("ascii"), hashlib.sha256).hexdigest()
                if prior["credential_digest"] != expected or prior["capabilities"] != json.dumps({
                    "codecs": body.codecs, "maxWidth": body.maxWidth,
                    "maxHeight": body.maxHeight, "maxFps": body.maxFps,
                }, separators=(",", ":"), sort_keys=True) or prior["name"] != body.name:
                    raise ApiError("idempotency_conflict", 409)
                return self._public_host(prior)
            if connection.execute("SELECT COUNT(*) FROM game_stream_hosts").fetchone()[0] >= MAX_HOSTS:
                raise ApiError("game_stream_limit_reached", 409)
            row = {"id": uuid.uuid4().hex, "registration_id": body.registrationId,
                   "revision": 1, "name": body.name, "pairing_revision": body.pairingRevision,
                   "credential_digest": hmac.new(self._key, body.credentialHandle.encode("ascii"), hashlib.sha256).hexdigest(),
                   "capabilities": json.dumps({"codecs": body.codecs, "maxWidth": body.maxWidth,
                                                "maxHeight": body.maxHeight, "maxFps": body.maxFps},
                                               separators=(",", ":"), sort_keys=True),
                   "active": 1, "created_at": now, "updated_at": now}
            row["envelope_tag"] = self._host_tag(row)
            connection.execute("INSERT INTO game_stream_hosts VALUES(?,?,?,?,?,?,?,?,?,?,?)", tuple(row.values()))
            return self._public_host(row)

    def hosts(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        with self.db.connection() as connection:
            user = self._actor(connection, actor)
            rows = [self._host(row) for row in connection.execute(
                "SELECT * FROM game_stream_hosts WHERE active=1 ORDER BY name,id LIMIT ?", (MAX_HOSTS,))]
        return {"schemaVersion": 1, "scope": self.scope.model_dump(),
                "accountRevision": user["revision"],
                "hosts": [self._public_host(row) for row in rows]}

    def open(self, actor, core_id, home_id, host_id, body):
        self._scope(core_id, home_id)
        now = self.settings.clock()
        if not now < body.expiresAt <= now + MAX_SESSION_TTL:
            raise ApiError("invalid_request", 400)
        raw = self._canonical(body)
        request_hash = hashlib.sha256(raw).hexdigest()
        with self.db.transaction() as connection:
            user = self._actor(connection, actor)
            if user["revision"] != body.accountRevision:
                raise ApiError("game_stream_authority_changed", 409)
            existing = connection.execute(
                "SELECT * FROM game_stream_sessions WHERE owner_id=? AND request_key=?",
                (actor.id, body.requestKey)).fetchone()
            if existing is not None:
                existing = self._session(existing)
                if existing["request_hash"] != request_hash:
                    raise ApiError("idempotency_conflict", 409)
                return self._public_session(existing)
            host = self._host(connection.execute(
                "SELECT * FROM game_stream_hosts WHERE id=?", (host_id,)).fetchone())
            if not host["active"] or (host["revision"], host["pairing_revision"]) != (
                body.expectedHostRevision, body.expectedPairingRevision):
                raise ApiError("game_stream_authority_changed", 409)
            if connection.execute("SELECT COUNT(*) FROM game_stream_sessions").fetchone()[0] >= MAX_SESSIONS:
                raise ApiError("game_stream_limit_reached", 409)
            authority = json.dumps({key: value for key, value in body.model_dump().items()
                                   if key not in {"schemaVersion", "requestKey", "expiresAt"}},
                                  separators=(",", ":"), sort_keys=True)
            row = {"id": uuid.uuid4().hex, "owner_id": actor.id, "family_id": actor.family_id,
                   "host_id": host_id, "revision": 1, "request_key": body.requestKey,
                   "request_hash": request_hash, "authority": authority,
                   "expires_at": body.expiresAt, "state": "open", "created_at": now}
            row["envelope_tag"] = self._session_tag(row)
            connection.execute("INSERT INTO game_stream_sessions VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", tuple(row.values()))
            return self._public_session(row)

    def _public_session(self, row):
        authority = json.loads(row["authority"])
        return {"schemaVersion": 1, "id": row["id"], "hostId": row["host_id"],
                "revision": row["revision"], "state": row["state"],
                "expiresAt": row["expires_at"], "authority": authority}

    def _owned_session(self, connection, actor, session_id, expected):
        row = self._session(connection.execute(
            "SELECT * FROM game_stream_sessions WHERE id=?", (session_id,)).fetchone())
        if row["owner_id"] != actor.id or row["family_id"] != actor.family_id:
            raise ApiError("not_found", 404)
        if row["revision"] != expected or row["state"] != "open" or self.settings.clock() >= row["expires_at"]:
            raise ApiError("game_stream_authority_changed", 409)
        authority = json.loads(row["authority"])
        user = connection.execute(
            "SELECT revision FROM users WHERE id=?", (actor.id,)
        ).fetchone()
        host = self._host(connection.execute(
            "SELECT * FROM game_stream_hosts WHERE id=?", (row["host_id"],)
        ).fetchone())
        if (user is None or user["revision"] != authority["accountRevision"]
                or not host["active"]
                or host["revision"] != authority["expectedHostRevision"]
                or host["pairing_revision"] != authority["expectedPairingRevision"]):
            raise ApiError("game_stream_authority_changed", 409)
        return row

    def authorize(self, actor, core_id, home_id, session_id, body):
        self._scope(core_id, home_id)
        request_hash = hashlib.sha256(self._canonical(body)).hexdigest()
        now = self.settings.clock()
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            session = self._owned_session(connection, actor, session_id, body.expectedSessionRevision)
            existing = connection.execute(
                "SELECT * FROM game_stream_commands WHERE session_id=? AND request_key=?",
                (session_id, body.requestKey)).fetchone()
            if existing is not None:
                existing = self._command(existing)
                if existing["request_hash"] != request_hash:
                    raise ApiError("idempotency_conflict", 409)
                return self._public_command(existing)
            if connection.execute("SELECT COUNT(*) FROM game_stream_commands").fetchone()[0] >= MAX_COMMANDS:
                raise ApiError("game_stream_limit_reached", 409)
            row = {"id": uuid.uuid4().hex, "session_id": session["id"],
                   "request_key": body.requestKey, "request_hash": request_hash,
                   "intent": body.intent, "state": "authorized", "result": None,
                   "readback_revision": None, "created_at": now, "completed_at": None}
            row["envelope_tag"] = self._command_tag(row)
            connection.execute("INSERT INTO game_stream_commands VALUES(?,?,?,?,?,?,?,?,?,?,?)", tuple(row.values()))
            return self._public_command(row)

    def complete(self, actor, core_id, home_id, session_id, command_id, body):
        self._scope(core_id, home_id)
        valid_result = (
            body.state == "verified"
            and body.readbackRevision is not None
            and body.result in {"hostAwake", "appRunning", "streaming", "stopped"}
        ) or (
            body.state == "rejected"
            and body.readbackRevision is None
            and body.result == "rejected"
        ) or (
            body.state == "unknown"
            and body.readbackRevision is None
            and body.result == "unknown"
        )
        if not valid_result:
            raise ApiError("invalid_request", 400)
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            self._owned_session(connection, actor, session_id, body.expectedSessionRevision)
            command = self._command(connection.execute(
                "SELECT * FROM game_stream_commands WHERE id=? AND session_id=?", (command_id, session_id)
            ).fetchone())
            if command["state"] != "authorized":
                if (command["state"], command["result"], command["readback_revision"]) == (
                    body.state, body.result, body.readbackRevision):
                    return self._public_command(command)
                raise ApiError("game_stream_command_changed", 409)
            row = dict(command)
            row.update(state=body.state, result=body.result,
                       readback_revision=body.readbackRevision, completed_at=self.settings.clock())
            row["envelope_tag"] = self._command_tag(row)
            connection.execute("UPDATE game_stream_commands SET state=?,result=?,readback_revision=?,completed_at=?,envelope_tag=? WHERE id=?",
                               (row["state"], row["result"], row["readback_revision"],
                                row["completed_at"], row["envelope_tag"], row["id"]))
            return self._public_command(row)

    @staticmethod
    def _public_command(row):
        return {"schemaVersion": 1, "id": row["id"], "sessionId": row["session_id"],
                "intent": row["intent"], "state": row["state"], "result": row["result"],
                "readbackRevision": row["readback_revision"], "createdAt": row["created_at"],
                "completedAt": row["completed_at"]}
