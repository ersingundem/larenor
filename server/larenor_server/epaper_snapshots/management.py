"""Authenticated, persistent F58 e-paper management and delivery boundary."""

import hashlib
import hmac
import json
import uuid

from pydantic import ValidationError

from ..errors import ApiError, StartupError
from .models import (
    EpaperAuthority,
    EpaperDataSnapshot,
    EpaperDeliveryAck,
    EpaperDevice,
    EpaperLayout,
    EpaperPolicy,
    EpaperRenderSnapshot,
)
from .service import FRAME_BYTES, EpaperSnapshotService

MAX_DEVICES = 100
MAX_POLLS = 2_000
PREVIEW_TTL_SECONDS = 60


class EpaperManagement:
    """Owns mappings and receipts; bridge credentials never enter public records."""

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings = db, auth, settings
        self._key, self.context = key, context

    @staticmethod
    def _canonical(value) -> str:
        return json.dumps(
            value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
            allow_nan=False,
        )

    def _tag(self, kind: str, values) -> str:
        encoded = self._canonical(values).encode("utf-8")
        return hmac.new(
            self._key, f"larenor-epaper-{kind}-v1\0".encode("ascii") + encoded,
            hashlib.sha256,
        ).hexdigest()

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.context.coreId, self.context.homeId):
            raise ApiError("not_found", 404)

    def _facts(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT revision,role,disabled,must_change_password FROM users WHERE id=?",
            (actor.id,),
        ).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("invalid_session", 401)
        return row

    def authority(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        with self.db.connection() as connection:
            account = self._facts(connection, actor)
        return {
            "schemaVersion": 1,
            "coreId": self.context.coreId,
            "homeId": self.context.homeId,
            "accountId": actor.id,
            "sessionFamilyId": actor.family_id,
            "homeRevision": 1,
            "accountRevision": account["revision"],
            "sessionRevision": 1,
            "canManage": actor.role == "admin",
        }

    def _expected(self, actor, core_id, home_id, body, *, admin=False):
        current = self.authority(actor, core_id, home_id)
        expected = body.authority_fields()
        actual = {name: current[name] for name in expected}
        if expected != actual:
            raise ApiError("authority_changed", 409)
        if admin and actor.role != "admin":
            raise ApiError("forbidden", 403)
        return current

    def _device_tag(self, row):
        return self._tag("device", [
            row["device_id"], row["core_id"], row["home_id"], row["owner_id"],
            row["revision"], row["active"], row["name"], row["configuration"],
            row["snapshot"], row["verified_digest"], row["updated_at"],
        ])

    def _preview_tag(self, row):
        return self._tag("preview", [
            row["request_id"], row["device_id"], row["actor_id"],
            row["session_family_id"], row["action"], row["device_revision"],
            row["layout_revision"], row["expires_at"], row["state"],
            row["command_digest"],
        ])

    def _poll_tag(self, row):
        return self._tag("poll", [
            row["request_id"], row["device_id"], row["device_revision"],
            row["render_digest"], row["byte_length"], row["frame_count"],
            row["status"], row["received_frames"],
        ])

    def _configuration(self, row):
        if row is None or not hmac.compare_digest(
            row["authentication_tag"], self._device_tag(row)
        ):
            raise StartupError("epaper_snapshot_storage_invalid")
        try:
            raw = json.loads(row["configuration"])
            configuration = {
                "device": EpaperDevice.model_validate(raw["device"]),
                "layout": EpaperLayout.model_validate(raw["layout"]),
                "data": EpaperDataSnapshot.model_validate(raw["data"]),
                "policy": EpaperPolicy.model_validate(raw["policy"]),
                "ttlSeconds": raw["ttlSeconds"],
            }
            if row["snapshot"] is not None:
                configuration["snapshot"] = EpaperRenderSnapshot.model_validate_json(
                    row["snapshot"]
                )
        except (ValidationError, ValueError, TypeError, KeyError, json.JSONDecodeError):
            raise StartupError("epaper_snapshot_storage_invalid") from None
        return configuration

    def _row(self, connection, device_id, *, required=True):
        row = connection.execute(
            "SELECT * FROM epaper_devices WHERE device_id=?", (device_id,)
        ).fetchone()
        if row is None:
            if required:
                raise ApiError("not_found", 404)
            return None
        if (row["core_id"], row["home_id"]) != (
            self.context.coreId, self.context.homeId,
        ):
            raise ApiError("not_found", 404)
        self._configuration(row)
        return row

    def _compose(self, authority, configuration):
        device, layout, data, policy = (
            configuration[name] for name in ("device", "layout", "data", "policy")
        )
        low_authority = EpaperAuthority(
            schemaVersion=1,
            coreId=authority["coreId"],
            homeId=authority["homeId"],
            homeRevision=authority["homeRevision"],
            accountId=authority["accountId"],
            accountRevision=authority["accountRevision"],
            memberRevision=authority["accountRevision"],
            sessionFamilyId=authority["sessionFamilyId"],
            active=True,
            canPublishEpaper=authority["canManage"],
        )
        service = EpaperSnapshotService(
            authorityResolver=lambda account_id: low_authority if account_id == low_authority.accountId else None,
            deviceResolver=lambda device_id: device if device_id == device.deviceId else None,
            layoutResolver=lambda layout_id: layout if layout_id == layout.layoutId else None,
            dataResolver=lambda data_id: data if data_id == data.dataId else None,
            policyResolver=lambda policy_id: policy if policy_id == policy.policyId else None,
            clockMs=lambda: int(self.settings.clock() * 1000),
        )
        return service.compose(
            low_authority, device, layout, data, policy,
            ttlSeconds=configuration["ttlSeconds"],
        )

    def map_device(self, actor, core_id, home_id, body):
        authority = self._expected(actor, core_id, home_id, body, admin=True)
        try:
            device = EpaperDevice.model_validate(body.device)
            layout = EpaperLayout.model_validate(body.layout)
            data = EpaperDataSnapshot.model_validate(body.data)
            policy = EpaperPolicy.model_validate(body.policy)
        except (ValidationError, ValueError, TypeError):
            raise ApiError("epaper_content_rejected", 400) from None
        if any((item.coreId, item.homeId) != (core_id, home_id)
               for item in (device, layout, data, policy)):
            raise ApiError("authority_changed", 409)
        configuration = {
            "device": device, "layout": layout, "data": data, "policy": policy,
            "ttlSeconds": body.ttlSeconds,
        }
        snapshot = self._compose(authority, configuration)
        raw_configuration = self._canonical({
            key: value.model_dump(mode="json") if hasattr(value, "model_dump") else value
            for key, value in configuration.items()
        })
        now = self.settings.clock()
        with self.db.transaction() as connection:
            self._facts(connection, actor)
            old = self._row(connection, device.deviceId, required=False)
            actual_revision = 0 if old is None else old["revision"]
            if actual_revision != body.expectedMappingRevision:
                raise ApiError("revision_conflict", 409)
            if old is None and connection.execute(
                "SELECT COUNT(*) FROM epaper_devices"
            ).fetchone()[0] >= MAX_DEVICES:
                raise ApiError("epaper_device_limit", 409)
            row = {
                "device_id": device.deviceId, "core_id": core_id, "home_id": home_id,
                "owner_id": actor.id, "revision": actual_revision + 1, "active": 1,
                "name": body.name, "configuration": raw_configuration,
                "snapshot": snapshot.model_dump_json(), "verified_digest": None,
                "updated_at": now,
            }
            row["authentication_tag"] = self._device_tag(row)
            connection.execute(
                "INSERT INTO epaper_devices VALUES(?,?,?,?,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(device_id) DO UPDATE SET owner_id=excluded.owner_id,"
                "revision=excluded.revision,active=excluded.active,name=excluded.name,"
                "configuration=excluded.configuration,snapshot=excluded.snapshot,"
                "verified_digest=NULL,updated_at=excluded.updated_at,"
                "authentication_tag=excluded.authentication_tag",
                tuple(row.values()),
            )
        return self._public(authority, row)

    def _public(self, authority, row):
        configuration = self._configuration(row)
        device = configuration["device"]
        layout, data, policy = (
            configuration[name] for name in ("layout", "data", "policy")
        )
        snapshot = configuration.get("snapshot")
        now_ms = int(self.settings.clock() * 1000)
        if snapshot is None:
            trust = "empty"
        elif now_ms >= snapshot.expiresAtMs:
            trust = "stale"
        elif row["verified_digest"] == snapshot.renderDigest:
            trust = "verified"
        else:
            poll = None
            with self.db.connection() as connection:
                poll = connection.execute(
                    "SELECT status FROM epaper_polls WHERE device_id=? AND render_digest=? "
                    "ORDER BY rowid DESC LIMIT 1", (device.deviceId, snapshot.renderDigest),
                ).fetchone()
            trust = "partial" if poll is not None and poll["status"] == "partial" else "pending"
        return {
            "schemaVersion": 1,
            "authority": {key: authority[key] for key in (
                "coreId", "homeId", "accountId", "sessionFamilyId",
                "homeRevision", "accountRevision", "sessionRevision", "canManage",
            )},
            "deviceId": device.deviceId,
            "name": row["name"],
            "deviceRevision": str(device.revision),
            "mappingRevision": row["revision"],
            "bridgeRevision": str(device.bridgeRevision),
            "layoutRevision": str(layout.revision),
            "dataRevision": str(data.revision),
            "policyRevision": str(policy.revision),
            "stored": bool(row["active"]),
            "reachable": device.active and device.connectivity == "online",
            "snapshotTrust": trust,
            "snapshotDigest": None if snapshot is None else snapshot.renderDigest,
            "verifiedDigest": row["verified_digest"],
            "expiresAtMs": 0 if snapshot is None else snapshot.expiresAtMs,
        }

    def list_devices(self, actor, core_id, home_id, body):
        authority = self._expected(actor, core_id, home_id, body)
        with self.db.connection() as connection:
            self._facts(connection, actor)
            rows = connection.execute(
                "SELECT * FROM epaper_devices WHERE core_id=? AND home_id=? AND active=1 "
                "ORDER BY name,device_id LIMIT ?", (core_id, home_id, MAX_DEVICES + 1),
            ).fetchall()
        if len(rows) > MAX_DEVICES:
            raise ApiError("epaper_device_limit", 409)
        return {"schemaVersion": 1, "devices": [self._public(authority, row) for row in rows]}

    def readback(self, actor, core_id, home_id, device_id, body):
        authority = self._expected(actor, core_id, home_id, body)
        with self.db.connection() as connection:
            self._facts(connection, actor)
            row = self._row(connection, device_id)
        return self._public(authority, row)

    def preview(self, actor, core_id, home_id, device_id, body):
        authority = self._expected(actor, core_id, home_id, body, admin=True)
        if body.action != "refresh":
            raise ApiError("invalid_request", 400)
        now = self.settings.clock()
        with self.db.transaction() as connection:
            self._facts(connection, actor)
            device_row = self._row(connection, device_id)
            config = self._configuration(device_row)
            device, layout = config["device"], config["layout"]
            if body.expectedDeviceRevision != str(device.revision):
                raise ApiError("revision_conflict", 409)
            request_id = uuid.uuid4().hex
            command = {
                "authority": body.authority_fields(), "deviceId": device_id,
                "deviceRevision": device.revision, "layoutRevision": layout.revision,
                "action": body.action,
            }
            row = {
                "request_id": request_id, "device_id": device_id,
                "actor_id": actor.id, "session_family_id": actor.family_id,
                "action": body.action, "device_revision": device.revision,
                "layout_revision": layout.revision,
                "expires_at": now + PREVIEW_TTL_SECONDS, "state": "pending",
                "command_digest": hashlib.sha256(
                    b"larenor-epaper-command-v1\0" + self._canonical(command).encode("utf-8")
                ).hexdigest(),
            }
            row["authentication_tag"] = self._preview_tag(row)
            connection.execute(
                "INSERT INTO epaper_previews VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                tuple(row.values()),
            )
        return {
            "schemaVersion": 1, "authority": authority,
            "requestId": request_id, "deviceId": device_id,
            "deviceRevision": str(device.revision), "action": body.action,
            "expectedLayoutRevision": str(layout.revision),
            "expiresAtMs": int(row["expires_at"] * 1000),
        }

    def cancel_preview(self, actor, core_id, home_id, request_id, body):
        self._expected(actor, core_id, home_id, body, admin=True)
        with self.db.transaction() as connection:
            self._facts(connection, actor)
            row = connection.execute(
                "SELECT * FROM epaper_previews WHERE request_id=?", (request_id,)
            ).fetchone()
            if row is None:
                raise ApiError("not_found", 404)
            if not hmac.compare_digest(row["authentication_tag"], self._preview_tag(row)):
                raise StartupError("epaper_snapshot_storage_invalid")
            if (row["actor_id"], row["session_family_id"], row["state"]) != (
                actor.id, actor.family_id, "pending",
            ):
                raise ApiError("revision_conflict", 409)
            updated = dict(row)
            updated["state"] = "cancelled"
            updated["authentication_tag"] = self._preview_tag(updated)
            connection.execute(
                "UPDATE epaper_previews SET state=?,authentication_tag=? WHERE request_id=?",
                ("cancelled", updated["authentication_tag"], request_id),
            )

    def confirm(self, actor, core_id, home_id, request_id, body):
        authority = self._expected(actor, core_id, home_id, body, admin=True)
        with self.db.transaction() as connection:
            self._facts(connection, actor)
            preview = connection.execute(
                "SELECT * FROM epaper_previews WHERE request_id=?", (request_id,)
            ).fetchone()
            if preview is None or not hmac.compare_digest(
                preview["authentication_tag"], self._preview_tag(preview)
            ):
                raise ApiError("not_found", 404)
            if (
                preview["actor_id"] != actor.id
                or preview["session_family_id"] != actor.family_id
                or preview["state"] != "pending"
                or self.settings.clock() >= preview["expires_at"]
            ):
                raise ApiError("revision_conflict", 409)
            row = self._row(connection, preview["device_id"])
            config = self._configuration(row)
            if (
                config["device"].revision != preview["device_revision"]
                or config["layout"].revision != preview["layout_revision"]
            ):
                raise ApiError("revision_conflict", 409)
            snapshot = self._compose(authority, config)
            updated = dict(row)
            updated["snapshot"] = snapshot.model_dump_json()
            updated["verified_digest"] = None
            updated["updated_at"] = self.settings.clock()
            updated["authentication_tag"] = self._device_tag(updated)
            connection.execute(
                "UPDATE epaper_devices SET snapshot=?,verified_digest=NULL,updated_at=?,"
                "authentication_tag=? WHERE device_id=?",
                (updated["snapshot"], updated["updated_at"], updated["authentication_tag"], row["device_id"]),
            )
            changed = dict(preview)
            changed["state"] = "published"
            changed["authentication_tag"] = self._preview_tag(changed)
            connection.execute(
                "UPDATE epaper_previews SET state='published',authentication_tag=? WHERE request_id=?",
                (changed["authentication_tag"], request_id),
            )
        # Publication is not delivery. The Client must wait for bridge readback.
        return {
            "schemaVersion": 1, "authority": authority,
            "requestId": request_id, "deviceId": preview["device_id"],
            "deviceRevision": str(preview["device_revision"]),
            "action": preview["action"], "status": "uncertain",
            "observedLayoutRevision": None, "observedSnapshotDigest": None,
        }

    def poll(self, actor, core_id, home_id, device_id, body):
        self._expected(actor, core_id, home_id, body)
        with self.db.transaction() as connection:
            self._facts(connection, actor)
            device_row = self._row(connection, device_id)
            config = self._configuration(device_row)
            snapshot = config.get("snapshot")
            device = config["device"]
            if snapshot is None:
                raise ApiError("not_found", 404)
            if body.expectedDeviceRevision != device.revision:
                raise ApiError("revision_conflict", 409)
            if int(self.settings.clock() * 1000) >= snapshot.expiresAtMs:
                raise ApiError("epaper_snapshot_stale", 409)
            raw = snapshot.model_dump_json().encode("utf-8")
            byte_length = len(raw)
            frames = (byte_length + FRAME_BYTES - 1) // FRAME_BYTES
            if byte_length > 256 * 1024 or frames > 64:
                raise ApiError("epaper_content_rejected", 413)
            row = {
                "request_id": body.requestId, "device_id": device_id,
                "device_revision": device.revision,
                "render_digest": snapshot.renderDigest,
                "byte_length": byte_length, "frame_count": frames,
                "status": "pending", "received_frames": 0,
            }
            row["authentication_tag"] = self._poll_tag(row)
            prior = connection.execute(
                "SELECT * FROM epaper_polls WHERE request_id=?", (body.requestId,)
            ).fetchone()
            if prior is not None:
                if not hmac.compare_digest(prior["authentication_tag"], self._poll_tag(prior)):
                    raise StartupError("epaper_snapshot_storage_invalid")
                if any(prior[key] != row[key] for key in row):
                    raise ApiError("revision_conflict", 409)
            else:
                if connection.execute("SELECT COUNT(*) FROM epaper_polls").fetchone()[0] >= MAX_POLLS:
                    raise ApiError("epaper_poll_limit", 409)
                connection.execute(
                    "INSERT INTO epaper_polls VALUES(?,?,?,?,?,?,?,?,?)", tuple(row.values())
                )
        return {
            "schemaVersion": 1, "requestId": body.requestId,
            "deviceId": device_id, "deviceRevision": device.revision,
            "deviceConnectivity": device.connectivity,
            "snapshot": snapshot.model_dump(mode="json"),
            "byteLength": byte_length, "frameCount": frames,
        }

    def acknowledge(self, actor, core_id, home_id, device_id, body):
        self._expected(actor, core_id, home_id, body)
        try:
            ack = EpaperDeliveryAck.model_validate(body.ack)
        except (ValidationError, ValueError, TypeError):
            raise ApiError("invalid_request", 400) from None
        if (ack.coreId, ack.homeId, ack.deviceId) != (core_id, home_id, device_id):
            raise ApiError("revision_conflict", 409)
        with self.db.transaction() as connection:
            self._facts(connection, actor)
            device_row = self._row(connection, device_id)
            config = self._configuration(device_row)
            snapshot = config.get("snapshot")
            poll = connection.execute(
                "SELECT * FROM epaper_polls WHERE request_id=?", (ack.requestId,)
            ).fetchone()
            if snapshot is None or poll is None or not hmac.compare_digest(
                poll["authentication_tag"], self._poll_tag(poll)
            ):
                raise ApiError("revision_conflict", 409)
            expected = (
                config["device"].revision, config["layout"].revision,
                config["data"].revision, config["policy"].revision,
                snapshot.renderDigest, poll["byte_length"], poll["frame_count"],
            )
            actual = (
                ack.deviceRevision, ack.layoutRevision, ack.dataRevision,
                ack.policyRevision, ack.renderDigest, ack.byteLength, ack.frameCount,
            )
            if actual != expected or (
                ack.status == "complete" and ack.receivedFrames != ack.frameCount
            ) or (ack.status == "partial" and ack.receivedFrames >= ack.frameCount):
                raise ApiError("revision_conflict", 409)
            status = "verified" if ack.status == "complete" else "partial"
            if poll["status"] != "pending":
                if poll["status"] == status and poll["received_frames"] == ack.receivedFrames:
                    return {"schemaVersion": 1, "requestId": ack.requestId,
                            "status": status, "verified": status == "verified",
                            "snapshotDigest": snapshot.renderDigest}
                raise ApiError("revision_conflict", 409)
            changed = dict(poll)
            changed["status"], changed["received_frames"] = status, ack.receivedFrames
            changed["authentication_tag"] = self._poll_tag(changed)
            connection.execute(
                "UPDATE epaper_polls SET status=?,received_frames=?,authentication_tag=? WHERE request_id=?",
                (status, ack.receivedFrames, changed["authentication_tag"], ack.requestId),
            )
            if status == "verified":
                updated = dict(device_row)
                updated["verified_digest"] = snapshot.renderDigest
                updated["authentication_tag"] = self._device_tag(updated)
                connection.execute(
                    "UPDATE epaper_devices SET verified_digest=?,authentication_tag=? WHERE device_id=?",
                    (snapshot.renderDigest, updated["authentication_tag"], device_id),
                )
        return {"schemaVersion": 1, "requestId": ack.requestId,
                "status": status, "verified": status == "verified",
                "snapshotDigest": snapshot.renderDigest}

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                devices = connection.execute(
                    "SELECT * FROM epaper_devices LIMIT ?", (MAX_DEVICES + 1,)
                ).fetchall()
                if len(devices) > MAX_DEVICES:
                    raise ValueError("device_limit")
                for row in devices:
                    self._configuration(row)
                for table, tagger, limit in (
                    ("epaper_previews", self._preview_tag, MAX_POLLS),
                    ("epaper_polls", self._poll_tag, MAX_POLLS),
                ):
                    rows = connection.execute(f"SELECT * FROM {table} LIMIT ?", (limit + 1,)).fetchall()
                    if len(rows) > limit or any(
                        not hmac.compare_digest(row["authentication_tag"], tagger(row))
                        for row in rows
                    ):
                        raise ValueError("invalid_epaper_records")
        except (ValueError, TypeError, json.JSONDecodeError, OverflowError):
            raise StartupError("epaper_snapshot_storage_invalid") from None
