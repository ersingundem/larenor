import hashlib
import hmac
import json
import re
import secrets
import sqlite3
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from .models import CreatePairing, MqttAck, MqttCommand


_TOKEN = re.compile(r"^[A-Za-z0-9_-]{43}$")
_MAX_TTL = 90 * 24 * 60 * 60
_MAX_COMMAND_TTL = 300
_MAX_PAIRINGS = 128
_MAX_COMMANDS = 20_000


class KioskRemoteService:
    """Durable pairing and MQTT envelopes without starting a network listener."""

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings, self._key = db, auth, settings, key
        self.core_id, self.home_id = context.coreId, context.homeId
        self._cipher = AESGCM(key)

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.core_id, self.home_id):
            raise ApiError("not_found", 404)

    def _token_hash(self, token):
        return hmac.new(self._key, b"kiosk-remote-token-v1\0" + token.encode("ascii"), hashlib.sha256).hexdigest()

    def _pairing_aad(self, row):
        return json.dumps([
            self.core_id, self.home_id, row["id"], row["request_id"],
            row["request_hash"],
            row["device_id"], row["owner_id"], row["family_id"], row["revision"],
            row["name"], row["scopes"], row["expires_at"], row["active"],
            row["created_at"], row["updated_at"],
        ], separators=(",", ":"), ensure_ascii=True).encode("ascii")

    def _pairing_tag(self, row):
        payload = self._pairing_aad(row) + b"\0" + row["token_hash"].encode("ascii") + b"\0" + row["token_nonce"] + b"\0" + row["token_ciphertext"]
        return hmac.new(self._key, b"kiosk-remote-pairing-v1\0" + payload, hashlib.sha256).hexdigest()

    def _command_tag(self, row):
        payload = json.dumps([
            self.core_id, self.home_id, row["id"], row["pairing_id"],
            row["request_id"], row["sequence"], row["kind"], row["expires_at"],
            row["state"], row["result"], row["request_hash"], row["created_at"],
            row["completed_at"],
        ], separators=(",", ":"), ensure_ascii=True).encode("ascii")
        return hmac.new(self._key, b"kiosk-remote-command-v1\0" + payload, hashlib.sha256).hexdigest()

    def _validate_pairing(self, row):
        if row is None:
            raise ApiError("invalid_pairing", 401)
        try:
            scopes = json.loads(row["scopes"])
        except (TypeError, json.JSONDecodeError):
            raise ValueError("invalid_pairing") from None
        if (
            not isinstance(scopes, list)
            or scopes != sorted(set(scopes))
            or not scopes
            or not set(scopes) <= {"read", "control", "admin"}
            or row["active"] not in (0, 1)
            or type(row["revision"]) is not int
            or row["revision"] < 1
            or not isinstance(row["request_hash"], str)
            or re.fullmatch(r"[0-9a-f]{64}", row["request_hash"]) is None
            or not isinstance(row["token_nonce"], bytes)
            or len(row["token_nonce"]) != 12
            or not isinstance(row["token_ciphertext"], bytes)
            or not hmac.compare_digest(row["record_tag"], self._pairing_tag(row))
        ):
            raise ValueError("invalid_pairing")
        return scopes

    def _validate_command(self, row):
        if row is None or not hmac.compare_digest(row["record_tag"], self._command_tag(row)):
            raise ValueError("invalid_command")
        return row

    def _public(self, row, scopes=None):
        scopes = scopes or self._validate_pairing(row)
        return {
            "schemaVersion": 1,
            "id": row["id"],
            "deviceId": row["device_id"],
            "revision": row["revision"],
            "name": row["name"],
            "scopes": scopes,
            "state": "active" if row["active"] and self.settings.clock() < row["expires_at"] else "revoked",
            "expiresAt": row["expires_at"],
            "mqttClientId": "larenor-" + row["id"],
            "mqttTopicPrefix": "larenor/" + row["id"],
        }

    def create(self, actor, core_id, home_id, value):
        self._scope(core_id, home_id)
        body = CreatePairing.model_validate(value)
        now = float(self.settings.clock())
        if body.expiresAt <= now + 60 or body.expiresAt > now + _MAX_TTL:
            raise ApiError("pairing_expiry_invalid", 409)
        scopes = json.dumps(sorted(body.scopes), separators=(",", ":"))
        request_hash = hashlib.sha256(body.model_dump_json().encode()).hexdigest()
        self.auth.rate_limit([("kiosk_remote_create", actor.id, 30)])
        try:
            with self.db.transaction() as connection:
                self.auth.assert_current(connection, actor)
                user = connection.execute("SELECT role,disabled,must_change_password FROM users WHERE id=?", (actor.id,)).fetchone()
                if user is None or user["role"] != "admin" or user["disabled"] or user["must_change_password"]:
                    raise ApiError("forbidden", 403)
                old = connection.execute("SELECT * FROM kiosk_remote_pairings WHERE request_id=?", (body.requestId,)).fetchone()
                if old is not None:
                    old_scopes = self._validate_pairing(old)
                    if (
                        old["owner_id"] != actor.id
                        or old["family_id"] != actor.family_id
                        or not hmac.compare_digest(old["request_hash"], request_hash)
                        or not old["active"]
                        or now >= old["expires_at"]
                    ):
                        raise ApiError("pairing_request_conflict", 409)
                    token = self._cipher.decrypt(
                        old["token_nonce"], old["token_ciphertext"],
                        self._pairing_aad(old),
                    ).decode("ascii")
                    if not hmac.compare_digest(
                        old["token_hash"], self._token_hash(token)
                    ):
                        raise ValueError("invalid_pairing_token")
                    return {"pairing": self._public(old, old_scopes), "token": token}
                device = connection.execute("SELECT id,revision,active FROM managed_tablets WHERE id=?", (body.deviceId,)).fetchone()
                if device is None or not device["active"]:
                    raise ApiError("not_found", 404)
                if device["revision"] != body.expectedDeviceRevision:
                    raise ApiError("tablet_device_changed", 409)
                if connection.execute("SELECT COUNT(*) FROM kiosk_remote_pairings").fetchone()[0] >= _MAX_PAIRINGS:
                    raise ApiError("pairing_limit_reached", 409)
                token = secrets.token_urlsafe(32)
                row = {
                    "id": uuid.uuid4().hex, "request_id": body.requestId,
                    "request_hash": request_hash,
                    "device_id": body.deviceId, "owner_id": actor.id,
                    "family_id": actor.family_id, "revision": 1,
                    "name": body.name, "scopes": scopes,
                    "token_hash": self._token_hash(token),
                    "expires_at": body.expiresAt, "active": 1,
                    "created_at": now, "updated_at": now,
                }
                row["token_nonce"] = secrets.token_bytes(12)
                row["token_ciphertext"] = self._cipher.encrypt(row["token_nonce"], token.encode("ascii"), self._pairing_aad(row))
                row["record_tag"] = self._pairing_tag(row)
                connection.execute(
                    "INSERT INTO kiosk_remote_pairings VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (row["id"], row["request_id"], row["request_hash"],
                     row["device_id"],
                     row["owner_id"], row["family_id"], row["revision"],
                     row["name"], row["scopes"], row["token_hash"],
                     row["token_nonce"], row["token_ciphertext"],
                     row["expires_at"], row["active"], row["created_at"],
                     row["updated_at"], row["record_tag"]),
                )
                return {"pairing": self._public(row, sorted(body.scopes)), "token": token}
        except ApiError:
            raise
        except (InvalidTag, ValueError, sqlite3.Error):
            raise ApiError("kiosk_remote_storage_unavailable", 503) from None

    def list(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        self.auth.rate_limit([("kiosk_remote_list", actor.id, 120)])
        try:
            with self.db.connection() as connection:
                self.auth.assert_current(connection, actor)
                rows = connection.execute("SELECT * FROM kiosk_remote_pairings ORDER BY created_at,id").fetchall()
                return {"schemaVersion": 1, "pairings": [self._public(row) for row in rows]}
        except ApiError:
            raise
        except (ValueError, sqlite3.Error):
            raise ApiError("kiosk_remote_storage_unavailable", 503) from None

    def revoke(self, actor, core_id, home_id, pairing_id, expected):
        self._scope(core_id, home_id)
        self.auth.rate_limit([("kiosk_remote_revoke", actor.id, 60)])
        try:
            with self.db.transaction() as connection:
                self.auth.assert_current(connection, actor)
                row = connection.execute("SELECT * FROM kiosk_remote_pairings WHERE id=?", (pairing_id,)).fetchone()
                self._validate_pairing(row)
                if row["revision"] != expected:
                    raise ApiError("pairing_changed", 409)
                updated = dict(row)
                updated.update(revision=expected + 1, active=0, updated_at=float(self.settings.clock()))
                updated["record_tag"] = self._pairing_tag(updated)
                connection.execute("UPDATE kiosk_remote_pairings SET revision=?,active=0,updated_at=?,record_tag=? WHERE id=?", (updated["revision"], updated["updated_at"], updated["record_tag"], pairing_id))
        except ApiError:
            raise
        except (ValueError, sqlite3.Error):
            raise ApiError("kiosk_remote_storage_unavailable", 503) from None

    def _authenticate(self, pairing_id, token, scope):
        if not isinstance(token, str) or _TOKEN.fullmatch(token) is None:
            raise ApiError("invalid_pairing", 401)
        self.auth.rate_limit([("kiosk_remote_pair", pairing_id, 300), ("kiosk_remote_global", "all", 2000)])
        try:
            with self.db.connection() as connection:
                row = connection.execute("SELECT * FROM kiosk_remote_pairings WHERE id=?", (pairing_id,)).fetchone()
                scopes = self._validate_pairing(row)
                if not row["active"] or self.settings.clock() >= row["expires_at"] or not hmac.compare_digest(row["token_hash"], self._token_hash(token)):
                    raise ApiError("invalid_pairing", 401)
                if scope not in scopes and "admin" not in scopes:
                    raise ApiError("pairing_scope_denied", 403)
                return row, scopes
        except ApiError:
            raise
        except (ValueError, sqlite3.Error):
            raise ApiError("invalid_pairing", 401) from None

    def discovery(self, core_id, home_id, pairing_id, token):
        self._scope(core_id, home_id)
        row, _ = self._authenticate(pairing_id, token, "read")
        prefix = "larenor/" + row["id"]
        return {
            "schemaVersion": 1, "pairingId": row["id"],
            "deviceId": row["device_id"], "pairingRevision": row["revision"],
            "listenerEnabled": False, "commandRetainAllowed": False,
            "availabilityTopic": prefix + "/availability",
            "sensors": [
                {"kind": kind, "stateTopic": prefix + "/sensor/" + kind + "/state", "retained": True}
                for kind in ("battery", "network", "app_version", "kiosk_state")
            ],
        }

    def submit(self, core_id, home_id, pairing_id, token, value):
        self._scope(core_id, home_id)
        body = MqttCommand.model_validate(value)
        row, scopes = self._authenticate(pairing_id, token, "control")
        if body.kind == "lockKiosk" and "admin" not in scopes:
            raise ApiError("pairing_scope_denied", 403)
        if body.retained:
            raise ApiError("mqtt_retained_command_denied", 409)
        now = float(self.settings.clock())
        if body.expiresAt <= now or body.expiresAt > now + _MAX_COMMAND_TTL:
            raise ApiError("mqtt_command_expired", 409)
        request_hash = hashlib.sha256(body.model_dump_json().encode()).hexdigest()
        try:
            with self.db.transaction() as connection:
                current = connection.execute("SELECT * FROM kiosk_remote_pairings WHERE id=?", (pairing_id,)).fetchone()
                self._validate_pairing(current)
                if current["revision"] != row["revision"] or not current["active"]:
                    raise ApiError("pairing_changed", 409)
                old = connection.execute("SELECT * FROM kiosk_remote_commands WHERE pairing_id=? AND request_id=?", (pairing_id, body.requestId)).fetchone()
                if old is not None:
                    self._validate_command(old)
                    if not hmac.compare_digest(old["request_hash"], request_hash):
                        raise ApiError("mqtt_command_conflict", 409)
                    return self._ack(old, True), False
                maximum = connection.execute("SELECT COALESCE(MAX(sequence),0) FROM kiosk_remote_commands WHERE pairing_id=?", (pairing_id,)).fetchone()[0]
                if body.sequence <= maximum:
                    raise ApiError("mqtt_command_replay", 409)
                if connection.execute("SELECT COUNT(*) FROM kiosk_remote_commands").fetchone()[0] >= _MAX_COMMANDS:
                    raise ApiError("mqtt_command_limit_reached", 409)
                command = {
                    "id": uuid.uuid4().hex, "pairing_id": pairing_id,
                    "request_id": body.requestId, "sequence": body.sequence,
                    "kind": body.kind, "expires_at": body.expiresAt,
                    "state": "accepted", "result": None,
                    "request_hash": request_hash, "created_at": now,
                    "completed_at": None,
                }
                command["record_tag"] = self._command_tag(command)
                connection.execute(
                    "INSERT INTO kiosk_remote_commands VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                    tuple(command.values()),
                )
                return self._ack(command, False), True
        except ApiError:
            raise
        except (ValueError, sqlite3.Error):
            raise ApiError("kiosk_remote_storage_unavailable", 503) from None

    def complete(self, core_id, home_id, pairing_id, command_id, token, value):
        self._scope(core_id, home_id)
        body = MqttAck.model_validate(value)
        self._authenticate(pairing_id, token, "control")
        try:
            with self.db.transaction() as connection:
                old = connection.execute("SELECT * FROM kiosk_remote_commands WHERE id=? AND pairing_id=?", (command_id, pairing_id)).fetchone()
                self._validate_command(old)
                if old["sequence"] != body.sequence:
                    raise ApiError("mqtt_command_changed", 409)
                if old["state"] == "completed":
                    if old["result"] != body.result:
                        raise ApiError("mqtt_command_changed", 409)
                    return self._ack(old, True)
                if self.settings.clock() >= old["expires_at"]:
                    raise ApiError("mqtt_command_expired", 409)
                updated = dict(old)
                updated.update(state="completed", result=body.result, completed_at=float(self.settings.clock()))
                updated["record_tag"] = self._command_tag(updated)
                connection.execute("UPDATE kiosk_remote_commands SET state=?,result=?,completed_at=?,record_tag=? WHERE id=?", (updated["state"], updated["result"], updated["completed_at"], updated["record_tag"], command_id))
                return self._ack(updated, False)
        except ApiError:
            raise
        except (ValueError, sqlite3.Error):
            raise ApiError("kiosk_remote_storage_unavailable", 503) from None

    @staticmethod
    def _ack(row, replayed):
        return {"ack": {"schemaVersion": 1, "commandId": row["id"],
                        "requestId": row["request_id"], "sequence": row["sequence"],
                        "state": row["state"], "result": row["result"],
                        "replayed": replayed}}

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                pairings = connection.execute("SELECT * FROM kiosk_remote_pairings").fetchall()
                commands = connection.execute("SELECT * FROM kiosk_remote_commands").fetchall()
                if len(pairings) > _MAX_PAIRINGS or len(commands) > _MAX_COMMANDS:
                    raise ValueError("limit")
                for row in pairings:
                    self._validate_pairing(row)
                for row in commands:
                    self._validate_command(row)
        except (ValueError, sqlite3.Error):
            raise StartupError("kiosk_remote_storage_invalid") from None
