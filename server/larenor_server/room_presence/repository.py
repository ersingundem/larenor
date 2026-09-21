import hashlib
import hmac
import json
import secrets
import sqlite3
import threading

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from .fusion import RoomPresenceFusion
from .management_models import (
    CalibrationPreview,
    CalibrationPreviewCommand,
    CalibrationReceipt,
    PresenceClientAuthority,
    PresenceDevicePage,
    PresenceDeviceView,
    PresenceRouteBinding,
)
from .models import PresenceAuthority, PresenceEstimate, PresencePolicy


MAX_STATE_BYTES = 8 * 1024 * 1024
MAX_DEVICES = 100
MAX_RECEIPTS = 256


def _digest(value):
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


class RoomPresenceRepository:
    """Encrypted durable owner for local, privacy-reduced presence state."""

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings = db, auth, settings
        self.scope = HomeScope.model_validate(context.model_dump())
        self._key = key
        self._cipher = AESGCM(key)
        self._lock = threading.RLock()
        self._state = self._empty()
        self.validate_storage()

    @staticmethod
    def _empty():
        return {
            "schemaVersion": 1,
            "revision": 0,
            "devices": {},
            "previews": {},
            "receipts": {},
        }

    def _aad(self, revision):
        return (
            f"larenor-room-presence-v1:{self.scope.coreId}:"
            f"{self.scope.homeId}:{revision}"
        ).encode("ascii")

    def _actor(self, principal):
        with self.db.connection() as connection:
            self.auth.assert_current(connection, principal)
            row = connection.execute(
                "SELECT revision,role,disabled,must_change_password "
                "FROM users WHERE id=?",
                (principal.id,),
            ).fetchone()
        if (
            row is None
            or row["disabled"]
            or row["must_change_password"]
            or principal.must_change_password
        ):
            raise ApiError("invalid_session", 401)
        return row

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    @staticmethod
    def _safe_label(value):
        if (
            not isinstance(value, str)
            or not value.strip()
            or len(value) > 80
            or any(ord(char) < 32 or ord(char) == 127 for char in value)
        ):
            raise ValueError("invalid_label")
        return value.strip()

    def _validate_state(self, value):
        if not isinstance(value, dict) or set(value) != {
            "schemaVersion",
            "revision",
            "devices",
            "previews",
            "receipts",
        }:
            raise ValueError("invalid_room_presence_state")
        if value["schemaVersion"] != 1 or type(value["revision"]) is not int:
            raise ValueError("invalid_room_presence_state")
        if not 0 <= value["revision"] <= 2**63 - 1:
            raise ValueError("invalid_room_presence_state")
        devices, previews, receipts = (
            value["devices"],
            value["previews"],
            value["receipts"],
        )
        if (
            not isinstance(devices, dict)
            or len(devices) > MAX_DEVICES
            or not isinstance(previews, dict)
            or len(previews) > MAX_RECEIPTS
            or not isinstance(receipts, dict)
            or len(receipts) > MAX_RECEIPTS
        ):
            raise ValueError("invalid_room_presence_state")
        home_revisions = set()
        for device_id, record in devices.items():
            if not isinstance(record, dict) or set(record) != {
                "policy",
                "deviceName",
                "roomNames",
                "providerReachable",
                "calibrationRevision",
                "estimate",
                "fusion",
            }:
                raise ValueError("invalid_room_presence_state")
            policy = PresencePolicy.model_validate(record["policy"])
            if device_id != policy.device.deviceId or (
                policy.coreId,
                policy.homeId,
            ) != (self.scope.coreId, self.scope.homeId):
                raise ValueError("invalid_room_presence_state")
            home_revisions.add(policy.homeRevision)
            self._safe_label(record["deviceName"])
            names = record["roomNames"]
            if not isinstance(names, dict) or set(names) != {
                room.roomId for room in policy.rooms
            }:
                raise ValueError("invalid_room_presence_state")
            for label in names.values():
                self._safe_label(label)
            if type(record["providerReachable"]) is not bool:
                raise ValueError("invalid_room_presence_state")
            calibration = record["calibrationRevision"]
            if type(calibration) is not int or not 1 <= calibration <= 2**63 - 1:
                raise ValueError("invalid_room_presence_state")
            PresenceEstimate.model_validate(record["estimate"])
            engine = self._engine(policy)
            engine.restore_state(record["fusion"])
        if len(home_revisions) > 1:
            raise ValueError("invalid_room_presence_state")
        for request_id, raw in previews.items():
            if CalibrationPreview.model_validate(raw).requestId != request_id:
                raise ValueError("invalid_room_presence_state")
        for request_id, raw in receipts.items():
            if CalibrationReceipt.model_validate(raw).requestId != request_id:
                raise ValueError("invalid_room_presence_state")
        return value

    def _decode(self, row):
        if (
            row["singleton"] != 1
            or type(row["revision"]) is not int
            or not 0 <= row["revision"] <= 2**63 - 1
            or type(row["nonce"]) is not bytes
            or len(row["nonce"]) != 12
            or type(row["ciphertext"]) is not bytes
            or not 16 <= len(row["ciphertext"]) <= MAX_STATE_BYTES + 16
        ):
            raise ValueError("invalid_room_presence_state")
        plain = self._cipher.decrypt(
            row["nonce"], row["ciphertext"], self._aad(row["revision"])
        )
        if len(plain) > MAX_STATE_BYTES or b"rawIdentifier" in plain:
            raise ValueError("invalid_room_presence_state")
        state = self._validate_state(json.loads(plain.decode("utf-8")))
        if state["revision"] != row["revision"]:
            raise ValueError("invalid_room_presence_revision")
        return state

    def _read(self, connection):
        rows = connection.execute(
            "SELECT * FROM room_presence_state LIMIT 2"
        ).fetchall()
        if len(rows) > 1:
            raise ValueError("duplicate_room_presence_state")
        return self._empty() if not rows else self._decode(rows[0])

    def _sync(self):
        with self.db.connection() as connection:
            self._state = self._read(connection)

    def _persist(self, previous_revision):
        plain = json.dumps(
            self._state,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        if len(plain) > MAX_STATE_BYTES:
            raise ApiError("revision_conflict", 409)
        revision = self._state["revision"]
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(nonce, plain, self._aad(revision))
        with self.db.transaction() as connection:
            row = connection.execute(
                "SELECT revision FROM room_presence_state WHERE singleton=1"
            ).fetchone()
            current = 0 if row is None else row["revision"]
            if current != previous_revision:
                raise ApiError("revision_conflict", 409)
            connection.execute(
                "INSERT INTO room_presence_state VALUES(1,?,?,?) "
                "ON CONFLICT(singleton) DO UPDATE SET "
                "revision=excluded.revision,nonce=excluded.nonce,"
                "ciphertext=excluded.ciphertext",
                (revision, nonce, ciphertext),
            )

    def _engine(self, policy):
        return RoomPresenceFusion(
            authorityResolver=lambda _account: None,
            policyResolver=lambda policy_id: (
                policy if policy_id == policy.policyId else None
            ),
        )

    def _authority_for_fusion(self, principal, row, policy):
        return PresenceAuthority(
            schemaVersion=1,
            coreId=policy.coreId,
            homeId=policy.homeId,
            homeRevision=policy.homeRevision,
            accountId=principal.id,
            accountRevision=row["revision"],
            sessionFamilyId=principal.family_id,
            active=True,
            canReadPresence=True,
            canManagePresence=row["role"] == "admin",
        )

    def _home_revision(self):
        revisions = {
            PresencePolicy.model_validate(record["policy"]).homeRevision
            for record in self._state["devices"].values()
        }
        return next(iter(revisions)) if revisions else 1

    def _client_authority(self, principal, row, binding):
        fields = {
            "schemaVersion": 1,
            "coreId": self.scope.coreId,
            "homeId": self.scope.homeId,
            "accountId": principal.id,
            "sessionFamilyId": principal.family_id,
            "routeId": binding.routeId,
            "homeRevision": self._home_revision(),
            "accountRevision": row["revision"],
            "clientSessionRevision": binding.clientSessionRevision,
            "routeRevision": binding.routeRevision,
        }
        payload = json.dumps(fields, sort_keys=True, separators=(",", ":")).encode(
            "ascii"
        )
        return PresenceClientAuthority(
            **fields,
            bindingTag=hmac.new(
                self._key, b"room-presence-authority-v1\0" + payload, hashlib.sha256
            ).hexdigest(),
        )

    def _verify_authority(self, principal, raw):
        authority = PresenceClientAuthority.model_validate(raw)
        row = self._actor(principal)
        expected = (
            self.scope.coreId,
            self.scope.homeId,
            principal.id,
            principal.family_id,
            self._home_revision(),
            row["revision"],
        )
        actual = (
            authority.coreId,
            authority.homeId,
            authority.accountId,
            authority.sessionFamilyId,
            authority.homeRevision,
            authority.accountRevision,
        )
        if actual[:2] != expected[:2]:
            raise ApiError("not_found", 404)
        if actual[2:] != expected[2:]:
            raise ApiError("revision_conflict", 409)
        fields = authority.model_dump(mode="json")
        tag = fields.pop("bindingTag")
        payload = json.dumps(fields, sort_keys=True, separators=(",", ":")).encode(
            "ascii"
        )
        expected_tag = hmac.new(
            self._key, b"room-presence-authority-v1\0" + payload, hashlib.sha256
        ).hexdigest()
        if not hmac.compare_digest(tag, expected_tag):
            raise ApiError("revision_conflict", 409)
        return authority, row

    def validate_storage(self):
        try:
            with self._lock:
                self._sync()
        except (
            InvalidTag,
            UnicodeError,
            json.JSONDecodeError,
            sqlite3.Error,
            ValueError,
            TypeError,
            OverflowError,
        ):
            raise StartupError("room_presence_storage_invalid") from None

    def register_local(
        self,
        principal,
        raw_policy,
        *,
        device_name,
        room_names,
        provider_reachable,
    ):
        policy = PresencePolicy.model_validate(raw_policy)
        self._scope(policy.coreId, policy.homeId)
        row = self._actor(principal)
        if row["role"] != "admin":
            raise ApiError("forbidden", 403)
        if type(provider_reachable) is not bool or not isinstance(room_names, dict):
            raise ApiError("invalid_request")
        try:
            name = self._safe_label(device_name)
            names = {key: self._safe_label(value) for key, value in room_names.items()}
        except ValueError:
            raise ApiError("invalid_request") from None
        if set(names) != {room.roomId for room in policy.rooms}:
            raise ApiError("invalid_request")
        with self._lock:
            self._sync()
            if (
                policy.device.deviceId not in self._state["devices"]
                and len(self._state["devices"]) >= MAX_DEVICES
            ):
                raise ApiError("revision_conflict", 409)
            revisions = {
                PresencePolicy.model_validate(value["policy"]).homeRevision
                for value in self._state["devices"].values()
            }
            if revisions and revisions != {policy.homeRevision}:
                raise ApiError("revision_conflict", 409)
            before = self._state["revision"]
            estimate = PresenceEstimate(
                schemaVersion=1,
                estimateId=_digest(
                    {"deviceId": policy.device.deviceId, "registered": before + 1}
                )[:32],
                coreId=policy.coreId,
                homeId=policy.homeId,
                homeRevision=policy.homeRevision,
                deviceId=policy.device.deviceId,
                deviceRevision=policy.device.deviceRevision,
                modelId=policy.device.modelId,
                modelRevision=policy.device.modelRevision,
                policyId=policy.policyId,
                policyRevision=policy.policyRevision,
                consentId=policy.device.consentId,
                consentRevision=policy.device.consentRevision,
                status="unknown",
                roomId=None,
                roomRevision=None,
                confidencePermille=0,
                observedAtMs=0,
                sampleCount=0,
                transitionRevision=0,
                advisoryOnly=True,
                grantsAccess=False,
            )
            engine = self._engine(policy)
            self._state["devices"][policy.device.deviceId] = {
                "policy": policy.model_dump(mode="json"),
                "deviceName": name,
                "roomNames": names,
                "providerReachable": provider_reachable,
                "calibrationRevision": 1,
                "estimate": estimate.model_dump(mode="json"),
                "fusion": engine.snapshot_state(),
            }
            self._state["revision"] = before + 1
            try:
                self._persist(before)
            except Exception:
                self._sync()
                raise

    def fuse_local(self, principal, policy_id, raw_signals, *, now_ms):
        with self._lock:
            self._sync()
            row = self._actor(principal)
            record = next(
                (
                    value
                    for value in self._state["devices"].values()
                    if value["policy"]["policyId"] == policy_id
                ),
                None,
            )
            if record is None:
                raise ApiError("not_found", 404)
            policy = PresencePolicy.model_validate(record["policy"])
            engine = self._engine(policy)
            engine.restore_state(record["fusion"])
            authority = self._authority_for_fusion(principal, row, policy)
            engine._resolve_authority = lambda account_id: (
                authority if account_id == principal.id else None
            )
            before = self._state["revision"]
            estimate = engine.fuse(authority, policy, raw_signals, nowMs=now_ms)
            record["estimate"] = estimate.model_dump(mode="json")
            record["fusion"] = engine.snapshot_state()
            self._state["revision"] = before + 1
            try:
                self._persist(before)
            except Exception:
                self._sync()
                raise
            return estimate

    def scope_authority(self, principal, core_id, home_id, raw_binding):
        self._scope(core_id, home_id)
        binding = PresenceRouteBinding.model_validate(raw_binding)
        with self._lock:
            self._sync()
            return self._client_authority(principal, self._actor(principal), binding)

    def _view(self, authority, record):
        policy = PresencePolicy.model_validate(record["policy"])
        estimate = PresenceEstimate.model_validate(record["estimate"])
        configured = next(
            (
                room
                for room in policy.rooms
                if room.roomId == (estimate.roomId or policy.rooms[0].roomId)
            ),
            policy.rooms[0],
        )
        return PresenceDeviceView(
            schemaVersion=1,
            authority=authority,
            deviceId=policy.device.deviceId,
            deviceName=record["deviceName"],
            deviceRevision=policy.device.deviceRevision,
            modelRevision=policy.device.modelRevision,
            policyRevision=policy.policyRevision,
            consentRevision=policy.device.consentRevision,
            consentActive=policy.device.consentActive,
            configuredRoomId=configured.roomId,
            configuredRoomName=record["roomNames"][configured.roomId],
            configuredRoomRevision=configured.roomRevision,
            detectedRoomId=estimate.roomId,
            detectedRoomRevision=estimate.roomRevision,
            estimateRevision=estimate.estimateId,
            transitionRevision=estimate.transitionRevision,
            calibrationRevision=record["calibrationRevision"],
            state=estimate.status,
            confidencePermille=estimate.confidencePermille,
            sampleCount=estimate.sampleCount,
            observedAtMs=estimate.observedAtMs,
            stored=True,
            providerReachable=record["providerReachable"],
            advisoryOnly=True,
            grantsAccess=False,
        )

    def list_devices(self, principal, core_id, home_id, raw_authority):
        self._scope(core_id, home_id)
        self.auth.rate_limit([("room_presence_read", principal.id, 120)])
        with self._lock:
            self._sync()
            authority, _row = self._verify_authority(principal, raw_authority)
            devices = [
                self._view(authority, record)
                for _device, record in sorted(self._state["devices"].items())
            ]
            return PresenceDevicePage(
                schemaVersion=1, authority=authority, devices=devices
            )

    def readback(self, principal, core_id, home_id, device_id, raw_authority):
        page = self.list_devices(principal, core_id, home_id, raw_authority)
        matches = [value for value in page.devices if value.deviceId == device_id]
        if len(matches) != 1:
            raise ApiError("not_found", 404)
        return matches[0]

    def preview(self, principal, core_id, home_id, device_id, raw_command):
        self._scope(core_id, home_id)
        command = CalibrationPreviewCommand.model_validate(raw_command)
        if command.deviceId != device_id:
            raise ApiError("invalid_request")
        self.auth.rate_limit([("room_presence_write", principal.id, 30)])
        with self._lock:
            self._sync()
            authority, row = self._verify_authority(principal, command.authority)
            if row["role"] != "admin":
                raise ApiError("forbidden", 403)
            record = self._state["devices"].get(device_id)
            if record is None:
                raise ApiError("not_found", 404)
            policy = PresencePolicy.model_validate(record["policy"])
            room = next(
                (room for room in policy.rooms if room.roomId == command.roomId), None
            )
            if room is None:
                raise ApiError("not_found", 404)
            expected = (
                policy.device.deviceRevision,
                policy.device.modelRevision,
                room.roomRevision,
                policy.policyRevision,
                policy.device.consentRevision,
                record["calibrationRevision"],
            )
            actual = (
                command.expectedDeviceRevision,
                command.expectedModelRevision,
                command.expectedRoomRevision,
                command.expectedPolicyRevision,
                command.expectedConsentRevision,
                command.expectedCalibrationRevision,
            )
            if (
                actual != expected
                or not policy.active
                or not policy.device.consentActive
            ):
                raise ApiError("revision_conflict", 409)
            now_ms = int(self.settings.clock() * 1000)
            self._state["previews"] = {
                key: value
                for key, value in self._state["previews"].items()
                if value["expiresAtMs"] > now_ms
            }
            if len(self._state["previews"]) >= MAX_RECEIPTS:
                raise ApiError("revision_conflict", 409)
            request_id = secrets.token_hex(16)
            preview = CalibrationPreview(
                schemaVersion=1,
                authority=authority,
                requestId=request_id,
                deviceId=device_id,
                deviceRevision=policy.device.deviceRevision,
                modelRevision=policy.device.modelRevision,
                roomId=room.roomId,
                roomRevision=room.roomRevision,
                policyRevision=policy.policyRevision,
                consentRevision=policy.device.consentRevision,
                previousCalibrationRevision=record["calibrationRevision"],
                nextCalibrationRevision=record["calibrationRevision"] + 1,
                expiresAtMs=now_ms + 120_000,
            )
            before = self._state["revision"]
            self._state["previews"][request_id] = preview.model_dump(mode="json")
            self._state["revision"] = before + 1
            try:
                self._persist(before)
            except Exception:
                self._sync()
                raise
            return preview

    def confirm(self, principal, core_id, home_id, request_id, raw_preview):
        self._scope(core_id, home_id)
        preview = CalibrationPreview.model_validate(raw_preview)
        if preview.requestId != request_id:
            raise ApiError("invalid_request")
        self.auth.rate_limit([("room_presence_write", principal.id, 30)])
        with self._lock:
            self._sync()
            self._verify_authority(principal, preview.authority)
            replay = self._state["receipts"].get(request_id)
            if replay is not None:
                receipt = CalibrationReceipt.model_validate(replay)
                if receipt.authority != preview.authority:
                    raise ApiError("idempotency_conflict", 409)
                return receipt
            stored = self._state["previews"].get(request_id)
            if stored is None or CalibrationPreview.model_validate(stored) != preview:
                raise ApiError("revision_conflict", 409)
            if preview.expiresAtMs <= int(self.settings.clock() * 1000):
                raise ApiError("revision_conflict", 409)
            record = self._state["devices"].get(preview.deviceId)
            if record is None:
                raise ApiError("not_found", 404)
            policy = PresencePolicy.model_validate(record["policy"])
            room = next(
                (item for item in policy.rooms if item.roomId == preview.roomId), None
            )
            exact = room is not None and (
                policy.device.deviceRevision,
                policy.device.modelRevision,
                room.roomRevision,
                policy.policyRevision,
                policy.device.consentRevision,
                record["calibrationRevision"],
            ) == (
                preview.deviceRevision,
                preview.modelRevision,
                preview.roomRevision,
                preview.policyRevision,
                preview.consentRevision,
                preview.previousCalibrationRevision,
            )
            if not exact or not policy.active or not policy.device.consentActive:
                raise ApiError("revision_conflict", 409)
            receipt = CalibrationReceipt(
                schemaVersion=1,
                authority=preview.authority,
                requestId=request_id,
                deviceId=preview.deviceId,
                deviceRevision=preview.deviceRevision,
                modelRevision=preview.modelRevision,
                roomId=preview.roomId,
                roomRevision=preview.roomRevision,
                policyRevision=preview.policyRevision,
                consentRevision=preview.consentRevision,
                previousCalibrationRevision=preview.previousCalibrationRevision,
                observedCalibrationRevision=preview.nextCalibrationRevision,
                status="applied",
            )
            if len(self._state["receipts"]) >= MAX_RECEIPTS:
                raise ApiError("revision_conflict", 409)
            before = self._state["revision"]
            record["calibrationRevision"] = preview.nextCalibrationRevision
            self._state["receipts"][request_id] = receipt.model_dump(mode="json")
            self._state["revision"] = before + 1
            try:
                self._persist(before)
            except Exception:
                self._sync()
                raise
            return receipt
