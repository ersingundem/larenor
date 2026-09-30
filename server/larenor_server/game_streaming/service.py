import hashlib
import hmac
import json
import uuid

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope

MAX_PAIRINGS = 128
MAX_HOSTS = 64
MAX_APPS = 256
MAX_CATALOG_OBSERVATIONS = 2048
MAX_SESSIONS = 2048
MAX_COMMANDS = 8192
MAX_PAIRING_TTL = 300
MAX_SESSION_TTL = 3600
SESSION_RETENTION_GRACE = 300
SESSION_PRUNE_BATCH = MAX_SESSIONS
MAX_SAFE_INTEGER = 2**53 - 1

FIELDS = {
    "pairing": ("id", "owner_id", "family_id", "actor_revision", "revision",
                "request_key", "request_hash", "grant_digest", "expires_at", "state",
                "created_at", "completed_at", "host_id", "native_receipt_digest",
                "completion_hash"),
    "host": ("id", "pairing_id", "owner_id", "revision", "name",
             "pairing_revision", "binding_digest", "host_observation_digest",
             "capabilities", "catalog_revision", "catalog_digest",
             "last_readback_revision", "assurance", "active", "created_at", "updated_at"),
    "catalog": ("id", "host_id", "owner_id", "family_id", "actor_revision",
                "revision", "request_key", "request_hash", "grant_digest",
                "expected_host_revision", "expected_pairing_revision",
                "expected_catalog_revision", "expires_at", "state", "created_at",
                "completed_at", "native_receipt_digest", "completion_hash"),
    "app": ("id", "host_id", "sequence", "observation_digest", "revision", "name", "active"),
    "session": ("id", "owner_id", "family_id", "host_id", "app_id", "revision",
                "request_key", "request_hash", "core_authority", "client_authority",
                "expires_at", "state", "last_request_key", "last_request_hash",
                "created_at", "updated_at"),
    "command": ("id", "session_id", "request_key", "request_hash", "intent", "state",
                "result", "observation_kind", "readback_revision", "native_receipt_digest",
                "grant_digest", "completion_hash", "created_at", "completed_at"),
    "revocation": ("id", "host_id", "owner_id", "family_id", "request_key",
                   "request_hash", "host_revision", "binding_digest", "state",
                   "completion_hash", "created_at", "completed_at",
                   "readback_revision", "native_receipt_digest"),
}

V2_REVOCATION_FIELDS = (
    "id", "host_id", "owner_id", "family_id", "request_key", "request_hash",
    "host_revision", "binding_digest", "state", "completion_hash", "created_at",
    "completed_at",
)


class GameStreamAuthorityService:
    """Core authority journal. Native transport and credentials remain client-private."""

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings, self._key = db, auth, settings, key
        self.scope = HomeScope.model_validate(context.model_dump())

    def _tag(self, kind, row):
        payload = json.dumps(
            {name: row[name] for name in FIELDS[kind]}, separators=(",", ":"),
            sort_keys=True).encode("utf-8")
        return hmac.new(
            self._key, b"larenor-game-stream-v2\0" + kind.encode() + b"\0" + payload,
            hashlib.sha256).hexdigest()

    def _digest(self, domain, value):
        return hmac.new(
            self._key, b"larenor-game-stream-v2-private\0" + domain.encode()
            + b"\0" + value.encode("ascii"), hashlib.sha256).hexdigest()

    def _v2_revocation_tag(self, row):
        payload = json.dumps(
            {name: row[name] for name in V2_REVOCATION_FIELDS},
            separators=(",", ":"), sort_keys=True).encode("utf-8")
        return hmac.new(
            self._key, b"larenor-game-stream-v2\0revocation\0" + payload,
            hashlib.sha256).hexdigest()

    @staticmethod
    def _canonical(value):
        if hasattr(value, "model_dump"):
            value = value.model_dump(mode="json")
        return json.dumps(value, separators=(",", ":"), sort_keys=True).encode()

    @classmethod
    def _hash(cls, value):
        return hashlib.sha256(cls._canonical(value)).hexdigest()

    def _checked(self, kind, row, *, missing=True):
        if row is None:
            if missing:
                raise ApiError("not_found", 404)
            return None
        if not hmac.compare_digest(row["envelope_tag"], self._tag(kind, row)):
            raise StartupError("game_stream_storage_invalid")
        return row

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    def _actor(self, connection, actor, *, admin=False):
        self.auth.assert_current(connection, actor)
        row = connection.execute("SELECT * FROM users WHERE id=?", (actor.id,)).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("invalid_session", 401)
        if type(row["revision"]) is not int or not 1 <= row["revision"] <= MAX_SAFE_INTEGER:
            raise ApiError("game_stream_authority_changed", 409)
        if admin and row["role"] != "admin":
            raise ApiError("forbidden", 403)
        return row

    def _write(self, connection, table, kind, row):
        row["envelope_tag"] = self._tag(kind, row)
        names = tuple(row)
        connection.execute(
            f"INSERT INTO {table} ({','.join(names)}) VALUES ({','.join('?' for _ in names)})",
            tuple(row[name] for name in names))

    def _update(self, connection, table, kind, row, changed):
        row = dict(row)
        row.update(changed)
        row["envelope_tag"] = self._tag(kind, row)
        values = {**changed, "envelope_tag": row["envelope_tag"]}
        connection.execute(
            f"UPDATE {table} SET {','.join(name + '=?' for name in values)} WHERE id=?",
            (*values.values(), row["id"]))
        return row

    def validate_storage(self):
        try:
            with self.db.transaction() as connection:
                for table, kind, limit in (
                    ("game_stream_pairings", "pairing", MAX_PAIRINGS),
                    ("game_stream_hosts", "host", MAX_HOSTS),
                    ("game_stream_catalog_observations", "catalog",
                     MAX_CATALOG_OBSERVATIONS),
                    ("game_stream_apps", "app", MAX_HOSTS * MAX_APPS),
                    ("game_stream_sessions", "session", MAX_SESSIONS),
                    ("game_stream_commands", "command", MAX_COMMANDS),
                    ("game_stream_revocations", "revocation", MAX_HOSTS * 4),
                ):
                    rows = connection.execute(f"SELECT * FROM {table} LIMIT ?", (limit + 1,)).fetchall()
                    if len(rows) > limit:
                        raise ValueError("limit")
                    for row in rows:
                        if (kind == "revocation"
                                and not hmac.compare_digest(
                                    row["envelope_tag"], self._tag(kind, row))):
                            if (row["readback_revision"] is not None
                                    or row["native_receipt_digest"] is not None
                                    or not hmac.compare_digest(
                                        row["envelope_tag"], self._v2_revocation_tag(row))):
                                raise ValueError("tag")
                            # v2 accepted a caller-declared local cleanup state.
                            # Preserve the audit row but retire that unsupported
                            # claim to unknown while sealing the new evidence fields.
                            changed = {
                                "readback_revision": None,
                                "native_receipt_digest": None,
                            }
                            if row["state"] == "local_cleared":
                                changed.update({"state": "unknown", "completion_hash": None})
                            row = self._update(
                                connection, table, kind, row, changed)
                        self._checked(kind, row)
                        for field in ("revision", "actor_revision", "pairing_revision",
                                      "catalog_revision", "readback_revision",
                                      "last_readback_revision", "host_revision",
                                      "expected_host_revision",
                                      "expected_pairing_revision",
                                      "expected_catalog_revision"):
                            if field in row.keys() and row[field] is not None and (
                                    type(row[field]) is not int
                                    or not 1 <= row[field] <= MAX_SAFE_INTEGER):
                                raise ValueError("unsafe_integer")
                        for field in ("capabilities", "core_authority", "client_authority"):
                            if field in row.keys():
                                value = json.loads(row[field])
                                if not isinstance(value, dict):
                                    raise ValueError("json")
                # An issued native dispatch cannot safely be re-issued after process loss.
                for command in connection.execute(
                        "SELECT * FROM game_stream_commands WHERE state='authorized'").fetchall():
                    self._update(connection, "game_stream_commands", "command", command, {
                        "state": "unknown", "result": "unknown", "observation_kind": "unknown",
                        "grant_digest": None, "completed_at": self.settings.clock(),
                    })
        except (TypeError, ValueError, json.JSONDecodeError):
            raise StartupError("game_stream_storage_invalid") from None

    @staticmethod
    def _json(value):
        return json.dumps(value, separators=(",", ":"), sort_keys=True)

    def _public_pairing(self, row, grant=None):
        return {"schemaVersion": 2, "id": row["id"], "revision": row["revision"],
                "state": row["state"], "pairingGrant": grant,
                "expiresAt": row["expires_at"]}

    @staticmethod
    def _public_catalog_intent(row, grant=None):
        return {"schemaVersion": 2, "id": row["id"], "hostId": row["host_id"],
                "revision": row["revision"], "state": row["state"],
                "catalogGrant": grant, "expiresAt": row["expires_at"]}

    def _public_host(self, row):
        capabilities = json.loads(row["capabilities"])
        return {"schemaVersion": 2, "id": row["id"], "revision": row["revision"],
                "pairingRevision": row["pairing_revision"],
                "catalogRevision": row["catalog_revision"], "name": row["name"],
                "assurance": row["assurance"], "active": bool(row["active"]),
                "codecs": capabilities["codecs"]}

    @staticmethod
    def _public_app(row):
        return {"schemaVersion": 2, "id": row["id"], "hostId": row["host_id"],
                "revision": row["revision"], "name": row["name"],
                "active": bool(row["active"])}

    def _public_session(self, row):
        core_authority = json.loads(row["core_authority"])
        return {"schemaVersion": 2, "id": row["id"], "hostId": row["host_id"],
                "appId": row["app_id"], "revision": row["revision"],
                "state": row["state"], "expiresAt": row["expires_at"],
                "coreAuthority": core_authority,
                "selectedQuality": core_authority["selectedQuality"],
                "clientAuthority": json.loads(row["client_authority"])}

    @staticmethod
    def _public_command(row):
        return {"schemaVersion": 2, "id": row["id"], "sessionId": row["session_id"],
                "intent": row["intent"], "state": row["state"], "result": row["result"],
                "observationKind": row["observation_kind"],
                "readbackRevision": row["readback_revision"],
                "createdAt": row["created_at"], "completedAt": row["completed_at"]}

    @staticmethod
    def _public_revocation(row):
        return {"schemaVersion": 2, "id": row["id"], "hostId": row["host_id"],
                "hostRevision": row["host_revision"], "state": row["state"],
                "readbackRevision": row["readback_revision"],
                "nativeReceiptDigest": row["native_receipt_digest"],
                "createdAt": row["created_at"], "completedAt": row["completed_at"]}

    def create_pairing(self, actor, core_id, home_id, body):
        self._scope(core_id, home_id)
        self.auth.rate_limit([("game_stream_write", actor.id, 120)])
        now = self.settings.clock()
        if not now < body.expiresAt <= now + MAX_PAIRING_TTL:
            raise ApiError("invalid_request", 400)
        request_hash = self._hash(body)
        with self.db.transaction() as connection:
            user = self._actor(connection, actor, admin=True)
            if user["revision"] != body.accountRevision:
                raise ApiError("game_stream_authority_changed", 409)
            prior = connection.execute(
                "SELECT * FROM game_stream_pairings "
                "WHERE owner_id=? AND family_id=? AND request_key=?",
                (actor.id, actor.family_id, body.requestKey)).fetchone()
            if prior is not None:
                prior = self._checked("pairing", prior)
                if prior["request_hash"] != request_hash:
                    raise ApiError("idempotency_conflict", 409)
                return self._public_pairing(prior)
            if connection.execute("SELECT COUNT(*) FROM game_stream_pairings").fetchone()[0] >= MAX_PAIRINGS:
                raise ApiError("game_stream_limit_reached", 409)
            grant = uuid.uuid4().hex
            row = {"id": uuid.uuid4().hex, "owner_id": actor.id,
                   "family_id": actor.family_id, "actor_revision": user["revision"],
                   "revision": 1, "request_key": body.requestKey,
                   "request_hash": request_hash,
                   "grant_digest": self._digest("pairing-grant", grant),
                   "expires_at": body.expiresAt, "state": "pending", "created_at": now,
                   "completed_at": None, "host_id": None,
                   "native_receipt_digest": None, "completion_hash": None}
            self._write(connection, "game_stream_pairings", "pairing", row)
            return self._public_pairing(row, grant)

    @staticmethod
    def _catalog_digest(apps):
        values = [{"observationId": app.observationId, "revision": app.revision,
                   "name": app.name} for app in apps]
        return hashlib.sha256(json.dumps(
            values, separators=(",", ":"), sort_keys=True).encode()).hexdigest()

    def complete_pairing(self, actor, core_id, home_id, pairing_id, body):
        self._scope(core_id, home_id)
        completion_hash = self._hash(body)
        now = self.settings.clock()
        with self.db.transaction() as connection:
            user = self._actor(connection, actor, admin=True)
            pairing = self._checked("pairing", connection.execute(
                "SELECT * FROM game_stream_pairings WHERE id=?", (pairing_id,)).fetchone())
            if pairing["owner_id"] != actor.id or pairing["family_id"] != actor.family_id:
                raise ApiError("not_found", 404)
            if pairing["state"] == "completed":
                if pairing["completion_hash"] != completion_hash:
                    raise ApiError("idempotency_conflict", 409)
                return self._pairing_result(connection, pairing, body.observation.receiptId)
            if (pairing["state"] != "pending" or pairing["revision"] != body.expectedPairingRevision
                    or now >= pairing["expires_at"] or user["revision"] != pairing["actor_revision"]
                    or pairing["grant_digest"] != self._digest("pairing-grant", body.pairingGrant)):
                raise ApiError("game_stream_authority_changed", 409)
            observation = body.observation
            if observation.catalogDigest != self._catalog_digest(observation.apps):
                raise ApiError("invalid_request", 400)
            if connection.execute("SELECT COUNT(*) FROM game_stream_hosts").fetchone()[0] >= MAX_HOSTS:
                raise ApiError("game_stream_limit_reached", 409)
            host = {"id": uuid.uuid4().hex, "pairing_id": pairing_id,
                    "owner_id": actor.id, "revision": 1, "name": observation.name,
                    "pairing_revision": observation.bindingRevision,
                    "binding_digest": self._digest("native-binding", observation.nativeBindingId),
                    "host_observation_digest": self._digest(
                        "host-observation", observation.hostObservationId),
                    "capabilities": self._json({"codecs": observation.codecs,
                        "engineRevision": observation.engineRevision,
                        "provider": observation.provider}),
                    "catalog_revision": observation.catalogRevision,
                    "catalog_digest": observation.catalogDigest,
                    "last_readback_revision": None, "assurance": "native_observed",
                    "active": 1, "created_at": now, "updated_at": now}
            self._write(connection, "game_stream_hosts", "host", host)
            for sequence, app in enumerate(observation.apps):
                self._write(connection, "game_stream_apps", "app", {
                    "id": uuid.uuid4().hex, "host_id": host["id"], "sequence": sequence,
                    "observation_digest": self._digest("app-observation", app.observationId),
                    "revision": app.revision, "name": app.name, "active": 1})
            pairing = self._update(connection, "game_stream_pairings", "pairing", pairing, {
                "revision": pairing["revision"] + 1, "grant_digest": None, "state": "completed",
                "completed_at": now, "host_id": host["id"],
                "native_receipt_digest": self._digest("pairing-receipt", observation.receiptId),
                "completion_hash": completion_hash,
            })
            return self._pairing_result(connection, pairing, observation.receiptId)

    def _pairing_result(self, connection, pairing, receipt_id):
        host = self._checked("host", connection.execute(
            "SELECT * FROM game_stream_hosts WHERE id=?", (pairing["host_id"],)).fetchone())
        apps = [self._checked("app", row) for row in connection.execute(
            "SELECT * FROM game_stream_apps WHERE host_id=? ORDER BY sequence", (host["id"],))]
        return {"schemaVersion": 2, "host": self._public_host(host),
                "apps": [self._public_app(row) for row in apps],
                "registrationMapping": {"nativeReceiptId": receipt_id, "hostId": host["id"],
                    "apps": [{"entryIndex": row["sequence"], "appId": row["id"]}
                             for row in apps]}}

    def hosts(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        with self.db.connection() as connection:
            user = self._actor(connection, actor)
            selected = connection.execute(
                "SELECT host.* FROM game_stream_hosts AS host "
                "JOIN game_stream_pairings AS pairing ON pairing.id=host.pairing_id "
                "WHERE host.owner_id=? AND pairing.family_id=? AND host.active=1 "
                "ORDER BY host.name,host.id LIMIT ?",
                (actor.id, actor.family_id, MAX_HOSTS)).fetchall()
            rows = [self._owned_host(connection, actor, row["id"]) for row in selected]
        return {"schemaVersion": 2, "scope": self.scope.model_dump(),
                "accountRevision": user["revision"],
                "hosts": [self._public_host(row) for row in rows]}

    def apps(self, actor, core_id, home_id, host_id):
        self._scope(core_id, home_id)
        with self.db.connection() as connection:
            self._actor(connection, actor)
            host = self._owned_host(connection, actor, host_id)
            rows = [self._checked("app", row) for row in connection.execute(
                "SELECT * FROM game_stream_apps WHERE host_id=? AND active=1 ORDER BY sequence",
                (host_id,))]
        return {"schemaVersion": 2, "hostRevision": host["revision"],
                "pairingRevision": host["pairing_revision"],
                "catalogRevision": host["catalog_revision"],
                "apps": [self._public_app(row) for row in rows]}

    def create_catalog_observation(self, actor, core_id, home_id, host_id, body):
        self._scope(core_id, home_id)
        now = self.settings.clock()
        if not now < body.expiresAt <= now + MAX_PAIRING_TTL:
            raise ApiError("invalid_request", 400)
        request_hash = self._hash(body)
        with self.db.transaction() as connection:
            user = self._actor(connection, actor)
            if user["revision"] != body.accountRevision:
                raise ApiError("game_stream_authority_changed", 409)
            prior = connection.execute(
                "SELECT * FROM game_stream_catalog_observations "
                "WHERE owner_id=? AND family_id=? AND request_key=?",
                (actor.id, actor.family_id, body.requestKey)).fetchone()
            if prior is not None:
                prior = self._checked("catalog", prior)
                if prior["request_hash"] != request_hash or prior["host_id"] != host_id:
                    raise ApiError("idempotency_conflict", 409)
                return self._public_catalog_intent(prior)
            host = self._owned_host(connection, actor, host_id)
            if (host["revision"], host["pairing_revision"], host["catalog_revision"]) != (
                    body.expectedHostRevision, body.expectedPairingRevision,
                    body.expectedCatalogRevision):
                raise ApiError("game_stream_authority_changed", 409)
            if connection.execute(
                    "SELECT COUNT(*) FROM game_stream_catalog_observations").fetchone()[0] >= MAX_CATALOG_OBSERVATIONS:
                raise ApiError("game_stream_limit_reached", 409)
            grant = uuid.uuid4().hex
            row = {"id": uuid.uuid4().hex, "host_id": host_id, "owner_id": actor.id,
                   "family_id": actor.family_id, "actor_revision": user["revision"],
                   "revision": 1, "request_key": body.requestKey,
                   "request_hash": request_hash,
                   "grant_digest": self._digest("catalog-grant", grant),
                   "expected_host_revision": body.expectedHostRevision,
                   "expected_pairing_revision": body.expectedPairingRevision,
                   "expected_catalog_revision": body.expectedCatalogRevision,
                   "expires_at": body.expiresAt, "state": "pending", "created_at": now,
                   "completed_at": None, "native_receipt_digest": None,
                   "completion_hash": None}
            self._write(connection, "game_stream_catalog_observations", "catalog", row)
            return self._public_catalog_intent(row, grant)

    def complete_catalog_observation(self, actor, core_id, home_id, host_id,
                                     observation_id, body):
        self._scope(core_id, home_id)
        completion_hash = self._hash(body)
        now = self.settings.clock()
        with self.db.transaction() as connection:
            user = self._actor(connection, actor)
            intent = self._checked("catalog", connection.execute(
                "SELECT * FROM game_stream_catalog_observations WHERE id=? AND host_id=?",
                (observation_id, host_id)).fetchone())
            if intent["owner_id"] != actor.id or intent["family_id"] != actor.family_id:
                raise ApiError("not_found", 404)
            if intent["state"] == "completed":
                if intent["completion_hash"] != completion_hash:
                    raise ApiError("idempotency_conflict", 409)
                return self._catalog_result(
                    connection, host_id, body.observation.receiptId)
            host = self._owned_host(connection, actor, host_id)
            observation = body.observation
            if (intent["state"] != "pending"
                    or intent["revision"] != body.expectedObservationRevision
                    or now >= intent["expires_at"]
                    or user["revision"] != intent["actor_revision"]
                    or intent["grant_digest"] != self._digest(
                        "catalog-grant", body.catalogGrant)
                    or (host["revision"], host["pairing_revision"],
                        host["catalog_revision"]) != (
                            intent["expected_host_revision"],
                            intent["expected_pairing_revision"],
                            intent["expected_catalog_revision"])
                    or observation.bindingRevision != host["pairing_revision"]
                    or self._digest("native-binding", observation.nativeBindingId)
                        != host["binding_digest"]
                    or observation.catalogRevision != host["catalog_revision"] + 1):
                raise ApiError("game_stream_authority_changed", 409)
            if observation.catalogDigest != self._catalog_digest(observation.apps):
                raise ApiError("invalid_request", 400)

            existing = {}
            stored_apps = connection.execute(
                    "SELECT * FROM game_stream_apps WHERE host_id=? ORDER BY sequence",
                    (host_id,)).fetchall()
            temporary_base = 1 + max(
                (stored["sequence"] for stored in stored_apps), default=MAX_APPS)
            for temporary, stored in enumerate(stored_apps):
                stored = self._checked("app", stored)
                # Free the bounded public sequence namespace before applying a
                # reorder; the UNIQUE(host_id,sequence) constraint stays active.
                stored = self._update(connection, "game_stream_apps", "app", stored, {
                    "sequence": temporary_base + temporary})
                existing[stored["observation_digest"]] = stored
            incoming = {
                self._digest("app-observation", item.observationId)
                for item in observation.apps
            }
            if len(set(existing) | incoming) > MAX_APPS:
                raise ApiError("game_stream_limit_reached", 409)
            active = []
            seen = set()
            for sequence, observed in enumerate(observation.apps):
                digest = self._digest("app-observation", observed.observationId)
                prior = existing.get(digest)
                if prior is None:
                    row = {"id": uuid.uuid4().hex, "host_id": host_id,
                           "sequence": sequence, "observation_digest": digest,
                           "revision": observed.revision, "name": observed.name, "active": 1}
                    self._write(connection, "game_stream_apps", "app", row)
                else:
                    if (observed.revision < prior["revision"]
                            or (observed.revision == prior["revision"]
                                and observed.name != prior["name"])):
                        raise ApiError("game_stream_authority_changed", 409)
                    row = self._update(connection, "game_stream_apps", "app", prior, {
                        "sequence": sequence, "revision": observed.revision,
                        "name": observed.name, "active": 1})
                active.append(row)
                seen.add(digest)
            for digest, prior in existing.items():
                if digest not in seen and prior["active"]:
                    self._update(connection, "game_stream_apps", "app", prior, {"active": 0})

            # Every existing session is bound to the old catalog revision.
            for session in connection.execute(
                    "SELECT * FROM game_stream_sessions WHERE host_id=? AND state='open'",
                    (host_id,)).fetchall():
                self._checked("session", session)
                self._retire_commands(connection, session["id"])
                self._update(connection, "game_stream_sessions", "session", session, {
                    "revision": session["revision"] + 1, "state": "retired",
                    "updated_at": now})
            self._update(connection, "game_stream_hosts", "host", host, {
                "catalog_revision": observation.catalogRevision,
                "catalog_digest": observation.catalogDigest, "updated_at": now})
            self._update(connection, "game_stream_catalog_observations", "catalog", intent, {
                "revision": intent["revision"] + 1, "grant_digest": None,
                "state": "completed", "completed_at": now,
                "native_receipt_digest": self._digest(
                    "catalog-receipt", observation.receiptId),
                "completion_hash": completion_hash})
            return self._catalog_result(connection, host_id, observation.receiptId)

    def _catalog_result(self, connection, host_id, receipt_id):
        host = self._checked("host", connection.execute(
            "SELECT * FROM game_stream_hosts WHERE id=?", (host_id,)).fetchone())
        apps = [self._checked("app", row) for row in connection.execute(
            "SELECT * FROM game_stream_apps WHERE host_id=? AND active=1 ORDER BY sequence",
            (host_id,))]
        return {"schemaVersion": 2, "hostRevision": host["revision"],
                "pairingRevision": host["pairing_revision"],
                "catalogRevision": host["catalog_revision"],
                "apps": [self._public_app(row) for row in apps],
                "registrationMapping": {"nativeReceiptId": receipt_id,
                    "hostId": host_id,
                    "apps": [{"entryIndex": row["sequence"], "appId": row["id"]}
                             for row in apps]}}

    def _owned_host(self, connection, actor, host_id, *, active=True):
        host = self._checked("host", connection.execute(
            "SELECT * FROM game_stream_hosts WHERE id=?", (host_id,)).fetchone())
        if host["owner_id"] != actor.id:
            raise ApiError("not_found", 404)
        pairing = self._checked("pairing", connection.execute(
            "SELECT * FROM game_stream_pairings WHERE id=?",
            (host["pairing_id"],)).fetchone())
        if pairing["owner_id"] != actor.id or pairing["family_id"] != actor.family_id:
            raise ApiError("not_found", 404)
        if active and not host["active"]:
            raise ApiError("game_stream_authority_changed", 409)
        return host

    def open(self, actor, core_id, home_id, host_id, app_id, body):
        self._scope(core_id, home_id)
        now = self.settings.clock()
        if not now < body.expiresAt <= now + MAX_SESSION_TTL:
            raise ApiError("invalid_request", 400)
        request_hash = self._hash(body)
        with self.db.transaction() as connection:
            user = self._actor(connection, actor)
            if user["revision"] != body.accountRevision:
                raise ApiError("game_stream_authority_changed", 409)
            prior = connection.execute(
                "SELECT * FROM game_stream_sessions "
                "WHERE owner_id=? AND family_id=? AND request_key=?",
                (actor.id, actor.family_id, body.requestKey)).fetchone()
            if prior is not None:
                prior = self._checked("session", prior)
                if prior["request_hash"] != request_hash:
                    raise ApiError("idempotency_conflict", 409)
                return self._public_session(prior)
            host = self._owned_host(connection, actor, host_id)
            app = self._checked("app", connection.execute(
                "SELECT * FROM game_stream_apps WHERE id=? AND host_id=?", (app_id, host_id)).fetchone())
            capabilities = json.loads(host["capabilities"])
            quality = body.selectedQuality.model_dump()
            if (not app["active"] or (host["revision"], host["pairing_revision"],
                    host["catalog_revision"], app["revision"]) !=
                    (body.expectedHostRevision, body.expectedPairingRevision,
                     body.expectedCatalogRevision, body.expectedAppRevision)
                    or quality["codec"] not in capabilities["codecs"]):
                raise ApiError("game_stream_authority_changed", 409)
            self._prune_expired_terminal_sessions(connection, now)
            if connection.execute("SELECT COUNT(*) FROM game_stream_sessions").fetchone()[0] >= MAX_SESSIONS:
                raise ApiError("game_stream_limit_reached", 409)
            row = {"id": uuid.uuid4().hex, "owner_id": actor.id, "family_id": actor.family_id,
                   "host_id": host_id, "app_id": app_id, "revision": 1,
                   "request_key": body.requestKey, "request_hash": request_hash,
                   "core_authority": self._json({"accountRevision": user["revision"],
                       "hostRevision": host["revision"], "pairingRevision": host["pairing_revision"],
                       "catalogRevision": host["catalog_revision"], "appRevision": app["revision"],
                       "selectedQuality": quality}),
                   "client_authority": self._json(body.clientAuthority.model_dump()),
                   "expires_at": body.expiresAt, "state": "open", "last_request_key": None,
                   "last_request_hash": None, "created_at": now, "updated_at": now}
            self._write(connection, "game_stream_sessions", "session", row)
            return self._public_session(row)

    def _owned_session(self, connection, actor, session_id, expected=None, *, require_open=True):
        row = self._owned_session_record(connection, actor, session_id, expected)
        if require_open and (row["state"] != "open" or self.settings.clock() >= row["expires_at"]):
            raise ApiError("game_stream_authority_changed", 409)
        authority = json.loads(row["core_authority"])
        user = connection.execute("SELECT revision FROM users WHERE id=?", (actor.id,)).fetchone()
        host = self._owned_host(connection, actor, row["host_id"], active=require_open)
        app = self._checked("app", connection.execute(
            "SELECT * FROM game_stream_apps WHERE id=? AND host_id=?",
            (row["app_id"], row["host_id"])).fetchone())
        if (user is None or user["revision"] != authority["accountRevision"]
                or host["revision"] != authority["hostRevision"]
                or host["pairing_revision"] != authority["pairingRevision"]
                or host["catalog_revision"] != authority["catalogRevision"]
                or app["revision"] != authority["appRevision"] or not app["active"]):
            raise ApiError("game_stream_authority_changed", 409)
        return row, host

    def _owned_session_record(self, connection, actor, session_id, expected=None):
        row = self._checked("session", connection.execute(
            "SELECT * FROM game_stream_sessions WHERE id=?", (session_id,)).fetchone())
        if row["owner_id"] != actor.id or row["family_id"] != actor.family_id:
            raise ApiError("not_found", 404)
        if expected is not None and row["revision"] != expected:
            raise ApiError("game_stream_authority_changed", 409)
        return row

    def session(self, actor, core_id, home_id, session_id):
        self._scope(core_id, home_id)
        with self.db.connection() as connection:
            self._actor(connection, actor)
            row = self._owned_session_record(connection, actor, session_id)
            return self._public_session(row)

    def retire(self, actor, core_id, home_id, session_id, body):
        self._scope(core_id, home_id)
        request_hash = self._hash(body)
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            row = self._owned_session_record(connection, actor, session_id)
            if row["state"] == "retired":
                return self._public_session(row)
            if row["revision"] != body.expectedSessionRevision:
                raise ApiError("game_stream_authority_changed", 409)
            self._retire_commands(connection, session_id)
            row = self._update(connection, "game_stream_sessions", "session", row, {
                "revision": row["revision"] + 1, "state": "retired",
                "last_request_key": body.requestKey, "last_request_hash": request_hash,
                "updated_at": self.settings.clock()})
            return self._public_session(row)

    def _retire_commands(self, connection, session_id):
        for command in connection.execute(
                "SELECT * FROM game_stream_commands WHERE session_id=? AND state='authorized'",
                (session_id,)).fetchall():
            self._checked("command", command)
            self._update(connection, "game_stream_commands", "command", command, {
                "state": "unknown", "result": "unknown", "observation_kind": "unknown",
                "grant_digest": None, "completed_at": self.settings.clock()})

    def _prune_expired_terminal_sessions(self, connection, now):
        expired = connection.execute(
            "SELECT * FROM game_stream_sessions WHERE expires_at<=? "
            "ORDER BY expires_at,id LIMIT ?", (now, SESSION_PRUNE_BATCH)).fetchall()
        for session in expired:
            session = self._checked("session", session)
            if session["state"] == "open":
                self._retire_commands(connection, session["id"])
                session = self._update(
                    connection, "game_stream_sessions", "session", session, {
                        "revision": session["revision"] + 1,
                        "state": "retired", "updated_at": now})
            commands = [self._checked("command", row) for row in connection.execute(
                "SELECT * FROM game_stream_commands WHERE session_id=? ORDER BY id",
                (session["id"],)).fetchall()]
            if (session["expires_at"] + SESSION_RETENTION_GRACE > now
                    or any(command["state"] not in ("native_observed", "rejected")
                           for command in commands)):
                continue
            connection.execute(
                "DELETE FROM game_stream_commands WHERE session_id=?", (session["id"],))
            connection.execute(
                "DELETE FROM game_stream_sessions WHERE id=?", (session["id"],))

    def authorize(self, actor, core_id, home_id, session_id, body):
        self._scope(core_id, home_id)
        request_hash = self._hash(body)
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            session, _ = self._owned_session(
                connection, actor, session_id, body.expectedSessionRevision)
            prior = connection.execute(
                "SELECT * FROM game_stream_commands WHERE session_id=? AND request_key=?",
                (session_id, body.requestKey)).fetchone()
            if prior is not None:
                prior = self._checked("command", prior)
                if prior["request_hash"] != request_hash:
                    raise ApiError("idempotency_conflict", 409)
                if prior["state"] == "authorized":
                    prior = self._update(connection, "game_stream_commands", "command", prior, {
                        "state": "unknown", "result": "unknown", "observation_kind": "unknown",
                        "grant_digest": None, "completed_at": self.settings.clock()})
                return {"schemaVersion": 2, "command": self._public_command(prior),
                        "dispatchGrant": None}
            unresolved = connection.execute(
                "SELECT * FROM game_stream_commands WHERE session_id=? AND state IN ('authorized','unknown') LIMIT 1",
                (session_id,)).fetchone()
            if unresolved is not None:
                self._checked("command", unresolved)
                raise ApiError("game_stream_command_changed", 409)
            if connection.execute("SELECT COUNT(*) FROM game_stream_commands").fetchone()[0] >= MAX_COMMANDS:
                raise ApiError("game_stream_limit_reached", 409)
            grant = uuid.uuid4().hex
            row = {"id": uuid.uuid4().hex, "session_id": session_id,
                   "request_key": body.requestKey, "request_hash": request_hash,
                   "intent": body.intent, "state": "authorized", "result": None,
                   "observation_kind": None, "readback_revision": None,
                   "native_receipt_digest": None,
                   "grant_digest": self._digest("dispatch-grant", grant),
                   "completion_hash": None, "created_at": self.settings.clock(),
                   "completed_at": None}
            self._write(connection, "game_stream_commands", "command", row)
            return {"schemaVersion": 2, "command": self._public_command(row),
                    "dispatchGrant": grant}

    def command(self, actor, core_id, home_id, session_id, command_id):
        self._scope(core_id, home_id)
        with self.db.connection() as connection:
            self._actor(connection, actor)
            self._owned_session_record(connection, actor, session_id)
            row = self._checked("command", connection.execute(
                "SELECT * FROM game_stream_commands WHERE id=? AND session_id=?",
                (command_id, session_id)).fetchone())
            return self._public_command(row)

    def complete(self, actor, core_id, home_id, session_id, command_id, body):
        self._scope(core_id, home_id)
        expected = {"wake": {("hostAwake", "serverInfoOnline")},
                    "launch": {("appRunning", "currentGameMatched")},
                    "stream": {("streaming", "connectionStarted")},
                    "stop": {("stopped", "connectionStopped"),
                             ("stopped", "connectionTerminated")}}
        completion_hash = self._hash(body)
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            _, host = self._owned_session(
                connection, actor, session_id, body.expectedSessionRevision)
            command = self._checked("command", connection.execute(
                "SELECT * FROM game_stream_commands WHERE id=? AND session_id=?",
                (command_id, session_id)).fetchone())
            if command["state"] != "authorized":
                if command["completion_hash"] == completion_hash:
                    return self._public_command(command)
                raise ApiError("game_stream_command_changed", 409)
            if command["grant_digest"] != self._digest("dispatch-grant", body.dispatchGrant):
                raise ApiError("game_stream_authority_changed", 409)
            observed = body.state == "native_observed" and (
                body.result, body.observationKind) in expected[command["intent"]]
            rejected = body.state == "rejected" and (
                body.result, body.observationKind) == ("rejected", "nativeRejected")
            unknown = body.state == "unknown" and (
                body.result, body.observationKind) == ("unknown", "unknown")
            if ((observed or rejected) != (body.readbackRevision is not None
                    and body.nativeReceiptDigest is not None)
                    or unknown != (body.readbackRevision is None
                                   and body.nativeReceiptDigest is None)
                    or not (observed or rejected or unknown)):
                raise ApiError("invalid_request", 400)
            if body.readbackRevision is not None:
                prior = host["last_readback_revision"]
                if prior is not None and body.readbackRevision <= prior:
                    raise ApiError("game_stream_authority_changed", 409)
                self._update(connection, "game_stream_hosts", "host", host, {
                    "last_readback_revision": body.readbackRevision,
                    "updated_at": self.settings.clock()})
            command = self._update(connection, "game_stream_commands", "command", command, {
                "state": body.state, "result": body.result,
                "observation_kind": body.observationKind,
                "readback_revision": body.readbackRevision,
                "native_receipt_digest": body.nativeReceiptDigest,
                "grant_digest": None, "completion_hash": completion_hash,
                "completed_at": self.settings.clock()})
            return self._public_command(command)

    def revoke(self, actor, core_id, home_id, host_id, body):
        self._scope(core_id, home_id)
        request_hash = self._hash(body)
        with self.db.transaction() as connection:
            self._actor(connection, actor, admin=True)
            prior = connection.execute(
                "SELECT * FROM game_stream_revocations "
                "WHERE owner_id=? AND family_id=? AND request_key=?",
                (actor.id, actor.family_id, body.requestKey)).fetchone()
            if prior is not None:
                prior = self._checked("revocation", prior)
                if prior["request_hash"] != request_hash:
                    raise ApiError("idempotency_conflict", 409)
                return self._public_revocation(prior)
            host = self._owned_host(connection, actor, host_id)
            if (host["revision"], host["pairing_revision"], host["catalog_revision"]) != (
                    body.expectedHostRevision, body.expectedPairingRevision,
                    body.expectedCatalogRevision):
                raise ApiError("game_stream_authority_changed", 409)
            now = self.settings.clock()
            host = self._update(connection, "game_stream_hosts", "host", host, {
                "revision": host["revision"] + 1, "active": 0, "updated_at": now})
            for session in connection.execute(
                    "SELECT * FROM game_stream_sessions WHERE host_id=? AND state='open'",
                    (host_id,)).fetchall():
                self._checked("session", session)
                self._retire_commands(connection, session["id"])
                self._update(connection, "game_stream_sessions", "session", session, {
                    "revision": session["revision"] + 1, "state": "retired",
                    "updated_at": now})
            row = {"id": uuid.uuid4().hex, "host_id": host_id, "owner_id": actor.id,
                   "family_id": actor.family_id,
                   "request_key": body.requestKey, "request_hash": request_hash,
                   "host_revision": host["revision"], "binding_digest": host["binding_digest"],
                   "state": "core_retired", "completion_hash": None,
                   "created_at": now, "completed_at": None,
                   "readback_revision": None, "native_receipt_digest": None}
            self._write(connection, "game_stream_revocations", "revocation", row)
            return self._public_revocation(row)

    def complete_revocation(self, actor, core_id, home_id, host_id, revocation_id, body):
        self._scope(core_id, home_id)
        completion_hash = self._hash(body)
        with self.db.transaction() as connection:
            self._actor(connection, actor, admin=True)
            row = self._checked("revocation", connection.execute(
                "SELECT * FROM game_stream_revocations WHERE id=? AND host_id=?",
                (revocation_id, host_id)).fetchone())
            if row["owner_id"] != actor.id or row["family_id"] != actor.family_id:
                raise ApiError("not_found", 404)
            host = self._owned_host(connection, actor, host_id, active=False)
            if (host["active"] or host["revision"] != row["host_revision"]
                    or host["binding_digest"] != row["binding_digest"]):
                raise ApiError("game_stream_authority_changed", 409)
            if row["state"] != "core_retired":
                if row["completion_hash"] == completion_hash:
                    return self._public_revocation(row)
                raise ApiError("game_stream_authority_changed", 409)
            if body.readbackRevision is not None:
                prior = host["last_readback_revision"]
                if prior is not None and body.readbackRevision <= prior:
                    raise ApiError("game_stream_authority_changed", 409)
                self._update(connection, "game_stream_hosts", "host", host, {
                    "last_readback_revision": body.readbackRevision,
                    "updated_at": self.settings.clock()})
            row = self._update(connection, "game_stream_revocations", "revocation", row, {
                "state": body.state, "completion_hash": completion_hash,
                "readback_revision": body.readbackRevision,
                "native_receipt_digest": body.nativeReceiptDigest,
                "completed_at": self.settings.clock()})
            return self._public_revocation(row)
