import hashlib
import hmac
import json
import math
import re
import secrets
import sqlite3
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from . import schema
from .models import (
    CompleteTabletCommand,
    IssueTabletCommand,
    PollTabletCommands,
    RegisterTablet,
    StoredTablet,
    TabletHeartbeat,
    UpdateTabletProfile,
)


_IDENTITY = re.compile(r"^[0-9a-f]{32}$")
_DIGEST = re.compile(r"^[0-9a-f]{64}$")
_STANDARD_CAPABILITIES = ("notifications", "kiosk", "media", "screen")
_OWNER_CAPABILITIES = _STANDARD_CAPABILITIES + ("appRestart", "kioskLock")
_COMMAND_MODE = {
    "syncProfile": "standard",
    "refreshDashboard": "standard",
    "restartClient": "deviceOwner",
    "lockKiosk": "deviceOwner",
}


class TabletFleetService:
    """Session-bound device registry with bounded, replay-safe command delivery."""

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings, self._key = db, auth, settings, key
        self.scope = HomeScope.model_validate(context.model_dump())
        self._cipher = AESGCM(key)

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    @staticmethod
    def _finite(value):
        return type(value) is float and math.isfinite(value)

    def _device_aad(self, row):
        return (f"larenor-tablet-device-v1:{self.scope.coreId}:{self.scope.homeId}:"
                f"{row['id']}:{row['owner_id']}:{row['family_id']}:{row['revision']}:"
                f"{row['active']}:{row['created_at']}:{row['updated_at']}:{row['last_seen_at']}").encode("ascii")

    def _command_tag(self, row):
        payload = json.dumps([
            self.scope.coreId, self.scope.homeId, row["sequence"], row["id"],
            row["device_id"], row["request_key"], row["command"], row["required_mode"],
            row["state"], row["result"], row["created_at"], row["delivered_at"],
            row["completed_at"],
        ], separators=(",", ":"), allow_nan=False).encode("ascii")
        return hmac.new(self._key, b"larenor-tablet-command-v1\0" + payload,
                        hashlib.sha256).hexdigest()

    def _validate_device(self, row):
        if (row is None or any(not isinstance(row[field], str) for field in
                               ("id", "owner_id", "family_id"))
                or any(_IDENTITY.fullmatch(row[field]) is None for field in
                       ("id", "owner_id", "family_id"))
                or type(row["revision"]) is not int or not 1 <= row["revision"] <= 2**63 - 1
                or row["active"] not in (0, 1)
                or type(row["nonce"]) is not bytes or len(row["nonce"]) != 12
                or type(row["ciphertext"]) is not bytes or not 17 <= len(row["ciphertext"]) <= 2048
                or any(not self._finite(row[field]) for field in
                       ("created_at", "updated_at", "last_seen_at"))
                or row["created_at"] > row["updated_at"]
                or row["created_at"] > row["last_seen_at"]):
            raise ValueError("invalid_tablet")
        value = StoredTablet.model_validate_json(
            self._cipher.decrypt(row["nonce"], row["ciphertext"], self._device_aad(row)))
        if value.appliedProfileRevision > value.desiredProfileRevision:
            raise ValueError("invalid_tablet_profile")
        return value

    def _validate_command(self, row):
        if (row is None or type(row["sequence"]) is not int
                or not 1 <= row["sequence"] <= 2**63 - 1
                or any(not isinstance(row[field], str) for field in
                       ("id", "device_id", "request_key", "command", "required_mode",
                        "state", "envelope_tag"))
                or _IDENTITY.fullmatch(row["id"]) is None
                or _IDENTITY.fullmatch(row["device_id"]) is None
                or not 16 <= len(row["request_key"]) <= 128
                or row["command"] not in _COMMAND_MODE
                or row["required_mode"] != _COMMAND_MODE[row["command"]]
                or row["state"] not in {"pending", "delivered", "completed"}
                or row["result"] not in {None, "succeeded", "denied", "failed", "unsupported"}
                or not self._finite(row["created_at"])
                or row["delivered_at"] is not None and not self._finite(row["delivered_at"])
                or row["completed_at"] is not None and not self._finite(row["completed_at"])
                or (row["state"] == "pending" and
                    (row["delivered_at"] is not None or row["completed_at"] is not None or row["result"] is not None))
                or (row["state"] == "delivered" and
                    (row["delivered_at"] is None or row["completed_at"] is not None or row["result"] is not None))
                or (row["state"] == "completed" and
                    (row["delivered_at"] is None or row["completed_at"] is None or row["result"] is None))
                or _DIGEST.fullmatch(row["envelope_tag"]) is None
                or not hmac.compare_digest(row["envelope_tag"], self._command_tag(row))):
            raise ValueError("invalid_tablet_command")
        return row

    def _transaction(self, actor, core_id, home_id, *, write=False):
        self.auth.rate_limit([("tablet_fleet_write" if write else "tablet_fleet_read",
                               actor.id, 240)])
        self._scope(core_id, home_id)
        return self.db.transaction()

    def _actor(self, connection, actor, *, admin=False):
        self.auth.assert_current(connection, actor)
        row = connection.execute("SELECT * FROM users WHERE id=?", (actor.id,)).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("invalid_session", 401)
        if admin and row["role"] != "admin":
            raise ApiError("forbidden", 403)
        return row

    def _device(self, connection, device_id, *, actor=None, expected=None, active=False):
        row = connection.execute("SELECT * FROM managed_tablets WHERE id=?", (device_id,)).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        value = self._validate_device(row)
        if actor is not None and (row["owner_id"] != actor.id or row["family_id"] != actor.family_id):
            raise ApiError("not_found", 404)
        if expected is not None and row["revision"] != expected:
            raise ApiError("tablet_device_changed", 409)
        if active and not row["active"]:
            raise ApiError("tablet_device_inactive", 409)
        return row, value

    def _encrypt(self, row, value):
        nonce = secrets.token_bytes(12)
        return nonce, self._cipher.encrypt(
            nonce, value.model_dump_json().encode("utf-8"), self._device_aad(row))

    def _public_device(self, row, value):
        mode = value.managementMode
        return {"tablet": {"schemaVersion": 1, "ref": {
            **self.scope.model_dump(), "kind": "managed_tablet", "id": row["id"]},
            "revision": row["revision"], "name": value.name, "platform": value.platform,
            "managementMode": mode,
            "capabilities": list(_OWNER_CAPABILITIES if mode == "deviceOwner" else _STANDARD_CAPABILITIES),
            "clientVersion": value.clientVersion,
            "desiredProfileRevision": value.desiredProfileRevision,
            "appliedProfileRevision": value.appliedProfileRevision,
            "state": "active" if row["active"] else "revoked",
            "profileState": "current" if value.appliedProfileRevision == value.desiredProfileRevision
                            else "updateRequired",
            "lastSeenAt": row["last_seen_at"]}}

    def register(self, actor, core_id, home_id, value):
        body = RegisterTablet.model_validate(value)
        now = float(self.settings.clock())
        stored = StoredTablet(name=body.name, platform=body.platform,
                              managementMode=body.managementMode,
                              clientVersion=body.clientVersion,
                              desiredProfileRevision=body.appliedProfileRevision,
                              appliedProfileRevision=body.appliedProfileRevision)
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                self._actor(connection, actor)
                old = connection.execute(
                    "SELECT * FROM managed_tablets WHERE id=?", (body.registrationId,)
                ).fetchone()
                if old is not None:
                    current = self._validate_device(old)
                    if old["owner_id"] != actor.id or old["family_id"] != actor.family_id:
                        raise ApiError("not_found", 404)
                    if not old["active"] or current != stored:
                        raise ApiError("tablet_registration_replay", 409)
                    return self._public_device(old, current)
                if connection.execute("SELECT COUNT(*) FROM managed_tablets").fetchone()[0] >= schema.MAX_DEVICES:
                    raise ApiError("tablet_limit_reached", 409)
                row = {"id": body.registrationId, "owner_id": actor.id,
                       "family_id": actor.family_id, "revision": 1, "active": 1,
                       "created_at": now, "updated_at": now, "last_seen_at": now}
                nonce, ciphertext = self._encrypt(row, stored)
                connection.execute("INSERT INTO managed_tablets VALUES(?,?,?,?,?,?,?,?,?,?)", (
                    row["id"], row["owner_id"], row["family_id"], row["revision"], 1,
                    nonce, ciphertext, now, now, now))
                saved = connection.execute("SELECT * FROM managed_tablets WHERE id=?", (row["id"],)).fetchone()
                return self._public_device(saved, self._validate_device(saved))
        except ApiError:
            raise
        except (InvalidTag, ValueError, sqlite3.Error):
            raise ApiError("tablet_fleet_storage_unavailable", 503) from None

    def heartbeat(self, actor, core_id, home_id, device_id, value):
        body = TabletHeartbeat.model_validate(value)
        now = float(self.settings.clock())
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                self._actor(connection, actor)
                row, old = self._device(connection, device_id, actor=actor,
                                        expected=body.expectedRevision, active=True)
                if body.appliedProfileRevision > old.desiredProfileRevision:
                    raise ApiError("tablet_profile_changed", 409)
                stored = old.model_copy(update={"clientVersion": body.clientVersion,
                                                "appliedProfileRevision": body.appliedProfileRevision})
                updated = dict(row)
                updated.update(updated_at=now, last_seen_at=now)
                nonce, ciphertext = self._encrypt(updated, stored)
                connection.execute("UPDATE managed_tablets SET nonce=?,ciphertext=?,updated_at=?,last_seen_at=? "
                                   "WHERE id=? AND revision=?", (
                    nonce, ciphertext, now, now, device_id, row["revision"]))
                saved = connection.execute("SELECT * FROM managed_tablets WHERE id=?", (device_id,)).fetchone()
                return self._public_device(saved, self._validate_device(saved))
        except ApiError:
            raise
        except (InvalidTag, ValueError, sqlite3.Error):
            raise ApiError("tablet_fleet_storage_unavailable", 503) from None

    def list(self, actor, core_id, home_id):
        try:
            with self._transaction(actor, core_id, home_id) as connection:
                self._actor(connection, actor, admin=True)
                records = [self._public_device(row, self._validate_device(row))["tablet"]
                           for row in connection.execute(
                               "SELECT * FROM managed_tablets ORDER BY created_at,id").fetchall()]
                return {"schemaVersion": 1, "scope": self.scope.model_dump(), "tablets": records}
        except ApiError:
            raise
        except (InvalidTag, ValueError, sqlite3.Error):
            raise ApiError("tablet_fleet_storage_unavailable", 503) from None

    def update_profile(self, actor, core_id, home_id, device_id, value):
        body = UpdateTabletProfile.model_validate(value)
        now = float(self.settings.clock())
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                self._actor(connection, actor, admin=True)
                row, old = self._device(connection, device_id, expected=body.expectedRevision,
                                        active=True)
                if body.desiredProfileRevision < old.appliedProfileRevision:
                    raise ApiError("invalid_request")
                stored = old.model_copy(update={"desiredProfileRevision": body.desiredProfileRevision})
                updated = dict(row)
                updated.update(revision=row["revision"] + 1, updated_at=now)
                nonce, ciphertext = self._encrypt(updated, stored)
                connection.execute("UPDATE managed_tablets SET revision=?,nonce=?,ciphertext=?,updated_at=? "
                                   "WHERE id=? AND revision=?", (
                    updated["revision"], nonce, ciphertext, now, device_id, row["revision"]))
                saved = connection.execute("SELECT * FROM managed_tablets WHERE id=?", (device_id,)).fetchone()
                return self._public_device(saved, self._validate_device(saved))
        except ApiError:
            raise
        except (InvalidTag, ValueError, sqlite3.Error):
            raise ApiError("tablet_fleet_storage_unavailable", 503) from None

    def revoke(self, actor, core_id, home_id, device_id, expected_revision):
        now = float(self.settings.clock())
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                self._actor(connection, actor, admin=True)
                row, old = self._device(connection, device_id, expected=expected_revision)
                if not row["active"]:
                    return
                updated = dict(row)
                updated.update(revision=row["revision"] + 1, active=0, updated_at=now)
                nonce, ciphertext = self._encrypt(updated, old)
                connection.execute("UPDATE managed_tablets SET revision=?,active=0,nonce=?,ciphertext=?,updated_at=? "
                                   "WHERE id=? AND revision=?", (
                    updated["revision"], nonce, ciphertext, now, device_id, row["revision"]))
        except ApiError:
            raise
        except (InvalidTag, ValueError, sqlite3.Error):
            raise ApiError("tablet_fleet_storage_unavailable", 503) from None

    def _public_command(self, row):
        self._validate_command(row)
        return {"command": {"schemaVersion": 1, "id": row["id"],
            "sequence": row["sequence"], "command": row["command"],
            "requiredMode": row["required_mode"], "state": row["state"],
            "result": row["result"], "createdAt": row["created_at"],
            "completedAt": row["completed_at"]}}

    def issue(self, actor, core_id, home_id, device_id, value):
        body = IssueTabletCommand.model_validate(value)
        now = float(self.settings.clock())
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                self._actor(connection, actor, admin=True)
                _, device = self._device(connection, device_id,
                                         expected=body.expectedDeviceRevision, active=True)
                required = _COMMAND_MODE[body.command]
                if required == "deviceOwner" and device.managementMode != "deviceOwner":
                    raise ApiError("tablet_capability_unavailable", 409)
                old = connection.execute(
                    "SELECT * FROM managed_tablet_commands WHERE device_id=? AND request_key=?",
                    (device_id, body.requestKey)).fetchone()
                if old is not None:
                    self._validate_command(old)
                    if old["command"] != body.command:
                        raise ApiError("tablet_command_conflict", 409)
                    return self._public_command(old)
                if connection.execute("SELECT COUNT(*) FROM managed_tablet_commands").fetchone()[0] >= schema.MAX_COMMANDS:
                    raise ApiError("tablet_command_limit_reached", 409)
                command_id = uuid.uuid4().hex
                connection.execute("INSERT INTO managed_tablet_commands "
                    "(id,device_id,request_key,command,required_mode,state,result,created_at,delivered_at,completed_at,envelope_tag) "
                    "VALUES(?,?,?,?,?,'pending',NULL,?,NULL,NULL,'')", (
                        command_id, device_id, body.requestKey, body.command, required, now))
                row = connection.execute("SELECT * FROM managed_tablet_commands WHERE id=?", (command_id,)).fetchone()
                tag = self._command_tag(row)
                connection.execute("UPDATE managed_tablet_commands SET envelope_tag=? WHERE id=?", (tag, command_id))
                saved = connection.execute("SELECT * FROM managed_tablet_commands WHERE id=?", (command_id,)).fetchone()
                return self._public_command(saved)
        except ApiError:
            raise
        except (ValueError, sqlite3.Error):
            raise ApiError("tablet_fleet_storage_unavailable", 503) from None

    def poll(self, actor, core_id, home_id, device_id, value):
        body = PollTabletCommands.model_validate(value)
        now = float(self.settings.clock())
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                self._actor(connection, actor)
                row, _ = self._device(connection, device_id, actor=actor,
                                      expected=body.expectedDeviceRevision, active=True)
                commands = connection.execute(
                    "SELECT * FROM managed_tablet_commands WHERE device_id=? AND sequence>? "
                    "ORDER BY sequence LIMIT ?", (device_id, body.after, body.limit + 1)).fetchall()
                page, more = commands[:body.limit], len(commands) > body.limit
                output = []
                for command in page:
                    self._validate_command(command)
                    if command["state"] == "pending":
                        changed = dict(command)
                        changed.update(state="delivered", delivered_at=now)
                        tag = self._command_tag(changed)
                        connection.execute("UPDATE managed_tablet_commands SET state='delivered',"
                                           "delivered_at=?,envelope_tag=? WHERE sequence=? AND state='pending'",
                                           (now, tag, command["sequence"]))
                        command = connection.execute(
                            "SELECT * FROM managed_tablet_commands WHERE sequence=?",
                            (command["sequence"],)).fetchone()
                    output.append(self._public_command(command)["command"])
                return {"schemaVersion": 1, "tabletRevision": row["revision"],
                        "commands": output,
                        "nextAfter": page[-1]["sequence"] if more and page else None}
        except ApiError:
            raise
        except (ValueError, sqlite3.Error):
            raise ApiError("tablet_fleet_storage_unavailable", 503) from None

    def complete(self, actor, core_id, home_id, device_id, command_id, value):
        body = CompleteTabletCommand.model_validate(value)
        now = float(self.settings.clock())
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                self._actor(connection, actor)
                _, device = self._device(connection, device_id, actor=actor,
                                         expected=body.expectedDeviceRevision, active=True)
                if body.appliedProfileRevision > device.desiredProfileRevision:
                    raise ApiError("tablet_profile_changed", 409)
                row = connection.execute(
                    "SELECT * FROM managed_tablet_commands WHERE id=? AND device_id=?",
                    (command_id, device_id)).fetchone()
                if row is None or row["sequence"] != body.sequence:
                    raise ApiError("not_found", 404)
                self._validate_command(row)
                if row["state"] == "pending":
                    raise ApiError("tablet_command_not_delivered", 409)
                if row["state"] == "completed":
                    if row["result"] != body.result:
                        raise ApiError("tablet_command_changed", 409)
                    return self._public_command(row)
                changed = dict(row)
                changed.update(state="completed", result=body.result, completed_at=now)
                tag = self._command_tag(changed)
                connection.execute("UPDATE managed_tablet_commands SET state='completed',result=?,"
                                   "completed_at=?,envelope_tag=? WHERE id=? AND state='delivered'",
                                   (body.result, now, tag, command_id))
                saved = connection.execute(
                    "SELECT * FROM managed_tablet_commands WHERE id=?", (command_id,)).fetchone()
                return self._public_command(saved)
        except ApiError:
            raise
        except (ValueError, sqlite3.Error):
            raise ApiError("tablet_fleet_storage_unavailable", 503) from None

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                devices = connection.execute("SELECT * FROM managed_tablets").fetchall()
                commands = connection.execute(
                    "SELECT * FROM managed_tablet_commands ORDER BY sequence").fetchall()
                if len(devices) > schema.MAX_DEVICES or len(commands) > schema.MAX_COMMANDS:
                    raise ValueError("tablet_fleet_limit")
                device_ids = {row["id"] for row in devices}
                for row in devices:
                    self._validate_device(row)
                for row in commands:
                    self._validate_command(row)
                    if row["device_id"] not in device_ids:
                        raise ValueError("orphan_tablet_command")
        except (InvalidTag, ValueError, sqlite3.Error):
            raise StartupError("tablet_fleet_storage_invalid") from None
