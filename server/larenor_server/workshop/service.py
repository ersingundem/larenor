from dataclasses import dataclass
import hashlib
import hmac
import json
import math
import re
import secrets
import sqlite3
import threading
import uuid

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from . import schema
from .models import (
    ConfirmIntent,
    PreviewIntent,
    RegisterPrinter,
    UpdatePrinterState,
    safe_label,
)


_IDENTITY = re.compile(r"^[0-9a-f]{32}$")
_DIGEST = re.compile(r"^[0-9a-f]{64}$")
_PREVIEW_TTL_SECONDS = 60
_MAX_PREVIEWS = 128
_MAX_ACTOR_PREVIEWS = 4
_SAFETY_TTL_SECONDS = 30


@dataclass(frozen=True)
class _Pending:
    actor_id: str
    family_id: str
    printer_id: str
    preview_id: str
    token_hash: str
    request_hash: str
    expires_at: float
    body: dict


class WorkshopService:
    """No-execution authority for monitored printers and reviewed intents."""

    def __init__(self, db, auth, settings, key, context, services):
        self.db, self.auth, self.settings = db, auth, settings
        self._key, self.services = key, services
        self.scope = HomeScope.model_validate(context.model_dump())
        self._previews: dict[str, _Pending] = {}
        self._lock = threading.RLock()

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    @staticmethod
    def _finite(value):
        return type(value) is float and math.isfinite(value)

    def _actor(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT role,disabled,must_change_password FROM users WHERE id=?",
            (actor.id,),
        ).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("invalid_session", 401)
        if row["role"] != "admin":
            raise ApiError("forbidden", 403)

    def _transaction(self, actor, core_id, home_id, *, write=False):
        self.auth.rate_limit([
            ("workshop_write" if write else "workshop_read", actor.id, 240)
        ])
        self._scope(core_id, home_id)
        return self.db.transaction() if write else self.db.connection()

    def _printer_tag(self, row):
        fields = [
            self.scope.coreId, self.scope.homeId, row["id"], row["owner_id"],
            row["family_id"], row["revision"], row["service_id"],
            row["service_revision"], row["name"], row["job_revision"],
            row["job_id"], row["job_state"], row["progress_permille"],
            row["remaining_seconds"], row["material_revision"],
            row["material_kind"], row["remaining_grams"],
            row["safety_revision"], row["connectivity"], row["thermal"],
            row["filament"], row["door"], row["emergency"],
            row["observed_at"], row["updated_at"],
        ]
        encoded = json.dumps(
            fields, ensure_ascii=False, separators=(",", ":"), allow_nan=False
        ).encode("utf-8")
        return hmac.new(
            self._key, b"larenor-workshop-printer-v1\0" + encoded,
            hashlib.sha256,
        ).hexdigest()

    def _intent_tag(self, row):
        fields = [
            self.scope.coreId, self.scope.homeId, row["sequence"], row["id"],
            row["printer_id"], row["actor_id"], row["request_key"],
            row["action"], row["printer_revision"], row["service_revision"],
            row["job_revision"], row["material_revision"],
            row["safety_revision"], row["state"], row["effect"],
            row["created_at"],
        ]
        encoded = json.dumps(
            fields, separators=(",", ":"), allow_nan=False
        ).encode("ascii")
        return hmac.new(
            self._key, b"larenor-workshop-intent-v1\0" + encoded,
            hashlib.sha256,
        ).hexdigest()

    def _validate_printer(self, row):
        if (
            row is None
            or any(not isinstance(row[name], str) for name in (
                "id", "owner_id", "family_id", "service_id", "name",
                "job_state", "material_kind", "connectivity", "thermal",
                "filament", "door", "emergency", "envelope_tag",
            ))
            or any(_IDENTITY.fullmatch(row[name]) is None for name in (
                "id", "owner_id", "family_id", "service_id",
            ))
            or row["job_id"] is not None
            and (not isinstance(row["job_id"], str)
                 or _IDENTITY.fullmatch(row["job_id"]) is None)
            or any(type(row[name]) is not int or not 1 <= row[name] <= 2**63 - 1
                   for name in (
                       "revision", "service_revision", "job_revision",
                       "material_revision", "safety_revision",
                   ))
            or row["job_state"] not in {"idle", "printing", "paused", "completed", "error"}
            or (row["job_state"] == "idle") != (row["job_id"] is None)
            or type(row["progress_permille"]) is not int
            or not 0 <= row["progress_permille"] <= 1000
            or row["remaining_seconds"] is not None
            and (type(row["remaining_seconds"]) is not int
                 or not 0 <= row["remaining_seconds"] <= 31_536_000)
            or row["material_kind"] not in {"pla", "petg", "abs", "tpu", "asa", "other"}
            or not self._finite(row["remaining_grams"])
            or not 0 <= row["remaining_grams"] <= 100_000
            or row["connectivity"] not in {"online", "offline"}
            or row["thermal"] not in {"normal", "warning", "runaway"}
            or row["filament"] not in {"available", "low", "runout", "unknown"}
            or row["door"] not in {"closed", "open", "unknown"}
            or row["emergency"] not in {"clear", "triggered"}
            or not self._finite(row["observed_at"])
            or not self._finite(row["updated_at"])
            or row["observed_at"] > row["updated_at"] + 5
            or _DIGEST.fullmatch(row["envelope_tag"]) is None
            or not hmac.compare_digest(row["envelope_tag"], self._printer_tag(row))
        ):
            raise ValueError("invalid_workshop_printer")
        safe_label(row["name"])
        return row

    def _validate_intent(self, row):
        if (
            row is None
            or type(row["sequence"]) is not int
            or not 1 <= row["sequence"] <= 2**63 - 1
            or any(not isinstance(row[name], str) for name in (
                "id", "printer_id", "actor_id", "request_key", "action",
                "state", "effect", "envelope_tag",
            ))
            or any(_IDENTITY.fullmatch(row[name]) is None for name in (
                "id", "printer_id", "actor_id",
            ))
            or not 16 <= len(row["request_key"]) <= 128
            or re.fullmatch(r"[A-Za-z0-9._:-]+", row["request_key"]) is None
            or row["action"] not in {"pause", "cancel"}
            or any(type(row[name]) is not int or not 1 <= row[name] <= 2**63 - 1
                   for name in (
                       "printer_revision", "service_revision", "job_revision",
                       "material_revision", "safety_revision",
                   ))
            or row["state"] != "recorded"
            or row["effect"] != "notDispatched"
            or not self._finite(row["created_at"])
            or _DIGEST.fullmatch(row["envelope_tag"]) is None
            or not hmac.compare_digest(row["envelope_tag"], self._intent_tag(row))
        ):
            raise ValueError("invalid_workshop_intent")
        return row

    def _binding(self, connection, service_id, revision):
        try:
            return self.services._workshop_connection(
                connection, service_id, revision
            )
        except ApiError:
            raise ApiError("workshop_binding_changed", 409) from None

    def _printer(self, connection, printer_id, *, expected=None):
        row = connection.execute(
            "SELECT * FROM workshop_printers WHERE id=?", (printer_id,)
        ).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        self._validate_printer(row)
        if expected is not None and row["revision"] != expected:
            raise ApiError("workshop_state_changed", 409)
        return row

    def _fresh(self, row, now):
        return (
            row["observed_at"] <= now + 5
            and now - row["observed_at"] <= _SAFETY_TTL_SECONDS
        )

    def _available_actions(self, row, now):
        if not self._fresh(row, now) or any((
            row["connectivity"] != "online",
            row["thermal"] != "normal",
            row["filament"] not in {"available", "low"},
            row["door"] != "closed",
            row["emergency"] != "clear",
        )):
            return []
        if row["job_state"] == "printing":
            return ["pause", "cancel"]
        if row["job_state"] == "paused":
            return ["cancel"]
        return []

    def _public_printer(self, row, now):
        self._validate_printer(row)
        return {"printer": {
            "schemaVersion": 1,
            "ref": {**self.scope.model_dump(), "kind": "workshop_printer", "id": row["id"]},
            "revision": row["revision"],
            "name": row["name"],
            "serviceRef": {"id": row["service_id"], "revision": row["service_revision"]},
            "job": {
                "revision": row["job_revision"], "jobId": row["job_id"],
                "state": row["job_state"], "progressPermille": row["progress_permille"],
                "remainingSeconds": row["remaining_seconds"],
            },
            "material": {
                "revision": row["material_revision"], "kind": row["material_kind"],
                "remainingGrams": row["remaining_grams"],
            },
            "safety": {
                "revision": row["safety_revision"], "connectivity": row["connectivity"],
                "thermal": row["thermal"], "filament": row["filament"],
                "door": row["door"], "emergency": row["emergency"],
                "observedAt": row["observed_at"],
                "freshness": "current" if self._fresh(row, now) else "stale",
            },
            "availableActions": self._available_actions(row, now),
        }}

    @staticmethod
    def _state_columns(body):
        return {
            "job_id": body.job.jobId,
            "job_state": body.job.state,
            "progress_permille": body.job.progressPermille,
            "remaining_seconds": body.job.remainingSeconds,
            "material_kind": body.material.kind,
            "remaining_grams": body.material.remainingGrams,
            "connectivity": body.safety.connectivity,
            "thermal": body.safety.thermal,
            "filament": body.safety.filament,
            "door": body.safety.door,
            "emergency": body.safety.emergency,
            "observed_at": body.safety.observedAt,
        }

    def register(self, actor, core_id, home_id, value):
        body = RegisterPrinter.model_validate(value)
        now = float(self.settings.clock())
        if body.safety.observedAt > now + 5:
            raise ApiError("invalid_request", 400)
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                self._actor(connection, actor)
                self._binding(connection, body.serviceId, body.expectedServiceRevision)
                old = connection.execute(
                    "SELECT * FROM workshop_printers WHERE id=?", (body.registrationId,)
                ).fetchone()
                requested = self._state_columns(body)
                if old is not None:
                    self._validate_printer(old)
                    comparable = {
                        **requested, "name": body.name, "service_id": body.serviceId,
                        "service_revision": body.expectedServiceRevision,
                    }
                    if any(old[name] != value for name, value in comparable.items()):
                        raise ApiError("workshop_registration_replay", 409)
                    return self._public_printer(old, now)
                if connection.execute(
                    "SELECT COUNT(*) FROM workshop_printers"
                ).fetchone()[0] >= schema.MAX_PRINTERS:
                    raise ApiError("workshop_limit_reached", 409)
                row = {
                    "id": body.registrationId,
                    "owner_id": actor.id,
                    "family_id": actor.family_id,
                    "revision": 1,
                    "service_id": body.serviceId,
                    "service_revision": body.expectedServiceRevision,
                    "name": body.name,
                    "job_revision": 1,
                    "material_revision": 1,
                    "safety_revision": 1,
                    **requested,
                    "updated_at": now,
                }
                row["envelope_tag"] = self._printer_tag(row)
                connection.execute(
                    "INSERT INTO workshop_printers VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    tuple(row[name] for name in (
                        "id", "owner_id", "family_id", "revision", "service_id",
                        "service_revision", "name", "job_revision", "job_id", "job_state",
                        "progress_permille", "remaining_seconds", "material_revision",
                        "material_kind", "remaining_grams", "safety_revision", "connectivity",
                        "thermal", "filament", "door", "emergency", "observed_at",
                        "updated_at", "envelope_tag",
                    )),
                )
                saved = self._printer(connection, body.registrationId)
                return self._public_printer(saved, now)
        except ApiError:
            raise
        except (ValueError, sqlite3.Error):
            raise ApiError("workshop_storage_unavailable", 503) from None

    def list(self, actor, core_id, home_id):
        now = float(self.settings.clock())
        try:
            with self._transaction(actor, core_id, home_id) as connection:
                connection.execute("BEGIN")
                self._actor(connection, actor)
                rows = connection.execute(
                    "SELECT * FROM workshop_printers ORDER BY name COLLATE NOCASE,id LIMIT ?",
                    (schema.MAX_PRINTERS + 1,),
                ).fetchall()
                if len(rows) > schema.MAX_PRINTERS:
                    raise ValueError("workshop_printer_limit")
                return {"schemaVersion": 1, "printers": [
                    self._public_printer(row, now)["printer"] for row in rows
                ]}
        except ApiError:
            raise
        except (ValueError, sqlite3.Error):
            raise ApiError("workshop_storage_unavailable", 503) from None

    def update_state(self, actor, core_id, home_id, printer_id, value):
        body = UpdatePrinterState.model_validate(value)
        now = float(self.settings.clock())
        if body.safety.observedAt > now + 5:
            raise ApiError("invalid_request", 400)
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                self._actor(connection, actor)
                row = self._printer(
                    connection, printer_id, expected=body.expectedPrinterRevision
                )
                if any((
                    row["service_revision"] != body.expectedServiceRevision,
                    row["job_revision"] != body.expectedJobRevision,
                    row["material_revision"] != body.expectedMaterialRevision,
                    row["safety_revision"] != body.expectedSafetyRevision,
                )):
                    raise ApiError("workshop_state_changed", 409)
                self._binding(connection, row["service_id"], body.expectedServiceRevision)
                changed = dict(row)
                changed.update(self._state_columns(body))
                changed.update(
                    revision=row["revision"] + 1,
                    job_revision=row["job_revision"] + 1,
                    material_revision=row["material_revision"] + 1,
                    safety_revision=row["safety_revision"] + 1,
                    updated_at=now,
                )
                changed["envelope_tag"] = self._printer_tag(changed)
                connection.execute(
                    "UPDATE workshop_printers SET revision=?,job_revision=?,job_id=?,job_state=?,"
                    "progress_permille=?,remaining_seconds=?,material_revision=?,material_kind=?,"
                    "remaining_grams=?,safety_revision=?,connectivity=?,thermal=?,filament=?,door=?,"
                    "emergency=?,observed_at=?,updated_at=?,envelope_tag=? WHERE id=? AND revision=?",
                    (
                        changed["revision"], changed["job_revision"], changed["job_id"],
                        changed["job_state"], changed["progress_permille"],
                        changed["remaining_seconds"], changed["material_revision"],
                        changed["material_kind"], changed["remaining_grams"],
                        changed["safety_revision"], changed["connectivity"], changed["thermal"],
                        changed["filament"], changed["door"], changed["emergency"],
                        changed["observed_at"], now, changed["envelope_tag"],
                        printer_id, row["revision"],
                    ),
                )
                saved = self._printer(connection, printer_id)
                return self._public_printer(saved, now)
        except ApiError:
            raise
        except (ValueError, sqlite3.Error):
            raise ApiError("workshop_storage_unavailable", 503) from None

    def _authority_matches(self, row, body):
        return all((
            row["revision"] == body.expectedPrinterRevision,
            row["service_revision"] == body.expectedServiceRevision,
            row["job_revision"] == body.expectedJobRevision,
            row["material_revision"] == body.expectedMaterialRevision,
            row["safety_revision"] == body.expectedSafetyRevision,
        ))

    @staticmethod
    def _request_hash(body):
        encoded = json.dumps(
            body.model_dump(), sort_keys=True, separators=(",", ":"), allow_nan=False
        ).encode("ascii")
        return hashlib.sha256(encoded).hexdigest()

    def _intent_matches(self, row, body):
        return all((
            row["action"] == body.action,
            row["printer_revision"] == body.expectedPrinterRevision,
            row["service_revision"] == body.expectedServiceRevision,
            row["job_revision"] == body.expectedJobRevision,
            row["material_revision"] == body.expectedMaterialRevision,
            row["safety_revision"] == body.expectedSafetyRevision,
        ))

    def _assert_commandable(self, row, body, now):
        if not self._authority_matches(row, body):
            raise ApiError("workshop_state_changed", 409)
        if body.action not in self._available_actions(row, now):
            raise ApiError("workshop_safety_blocked", 409)

    def _prune_previews(self, now):
        for preview_id, pending in list(self._previews.items()):
            if now >= pending.expires_at:
                del self._previews[preview_id]

    def preview(self, actor, core_id, home_id, printer_id, value):
        body = PreviewIntent.model_validate(value)
        now = float(self.settings.clock())
        try:
            with self._lock:
                self._prune_previews(now)
                with self._transaction(actor, core_id, home_id) as connection:
                    connection.execute("BEGIN")
                    self._actor(connection, actor)
                    row = self._printer(
                        connection, printer_id, expected=body.expectedPrinterRevision
                    )
                    self._binding(connection, row["service_id"], body.expectedServiceRevision)
                    self._assert_commandable(row, body, now)
                    old = connection.execute(
                        "SELECT * FROM workshop_intents WHERE printer_id=? AND request_key=?",
                        (printer_id, body.requestKey),
                    ).fetchone()
                    if old is not None:
                        self._validate_intent(old)
                        if not self._intent_matches(old, body):
                            raise ApiError("workshop_intent_conflict", 409)
                    if (
                        len(self._previews) >= _MAX_PREVIEWS
                        or sum(p.actor_id == actor.id for p in self._previews.values())
                        >= _MAX_ACTOR_PREVIEWS
                    ):
                        raise ApiError("workshop_preview_limit", 409)
                    preview_id = uuid.uuid4().hex
                    token = secrets.token_urlsafe(32)
                    pending = _Pending(
                        actor_id=actor.id,
                        family_id=actor.family_id,
                        printer_id=printer_id,
                        preview_id=preview_id,
                        token_hash=hashlib.sha256(token.encode("ascii")).hexdigest(),
                        request_hash=self._request_hash(body),
                        expires_at=now + _PREVIEW_TTL_SECONDS,
                        body=body.model_dump(),
                    )
                    self._previews[preview_id] = pending
                    return {"preview": {
                        "schemaVersion": 1,
                        "id": preview_id,
                        "printerRef": {
                            **self.scope.model_dump(), "kind": "workshop_printer",
                            "id": printer_id,
                        },
                        "action": body.action,
                        "confirmationToken": token,
                        "expiresAt": pending.expires_at,
                    }}
        except ApiError:
            raise
        except (ValueError, sqlite3.Error):
            raise ApiError("workshop_storage_unavailable", 503) from None

    def _public_intent(self, row):
        self._validate_intent(row)
        return {
            "schemaVersion": 1,
            "id": row["id"],
            "sequence": row["sequence"],
            "printerRef": {
                **self.scope.model_dump(), "kind": "workshop_printer",
                "id": row["printer_id"],
            },
            "action": row["action"],
            "state": row["state"],
            "effect": row["effect"],
            "authority": {
                "printerRevision": row["printer_revision"],
                "serviceRevision": row["service_revision"],
                "jobRevision": row["job_revision"],
                "materialRevision": row["material_revision"],
                "safetyRevision": row["safety_revision"],
            },
            "createdAt": row["created_at"],
        }

    def confirm(self, actor, core_id, home_id, printer_id, preview_id, value):
        body = ConfirmIntent.model_validate(value)
        now = float(self.settings.clock())
        try:
            with self._lock:
                self._prune_previews(now)
                pending = self._previews.get(preview_id)
                supplied = hashlib.sha256(
                    body.confirmationToken.encode("ascii")
                ).hexdigest()
                if (
                    pending is None
                    or pending.actor_id != actor.id
                    or pending.family_id != actor.family_id
                    or pending.printer_id != printer_id
                    or not hmac.compare_digest(pending.token_hash, supplied)
                ):
                    raise ApiError("workshop_preview_invalid", 409)
                command = PreviewIntent.model_validate(pending.body)
                if not hmac.compare_digest(
                    pending.request_hash, self._request_hash(command)
                ):
                    raise ApiError("workshop_preview_invalid", 409)
                with self._transaction(actor, core_id, home_id, write=True) as connection:
                    self._actor(connection, actor)
                    old = connection.execute(
                        "SELECT * FROM workshop_intents WHERE printer_id=? AND request_key=?",
                        (printer_id, command.requestKey),
                    ).fetchone()
                    if old is not None:
                        self._validate_intent(old)
                        if not self._intent_matches(old, command):
                            raise ApiError("workshop_intent_conflict", 409)
                        # A retained receipt is authoritative after a lost HTTP ACK.
                        # Rechecking live safety here would hide the committed result;
                        # returning it does not dispatch or repeat an effect.
                        return {"receipt": self._public_intent(old)}
                    row = self._printer(
                        connection, printer_id,
                        expected=command.expectedPrinterRevision,
                    )
                    self._binding(
                        connection, row["service_id"], command.expectedServiceRevision
                    )
                    self._assert_commandable(row, command, now)
                    if connection.execute(
                        "SELECT COUNT(*) FROM workshop_intents"
                    ).fetchone()[0] >= schema.MAX_INTENTS:
                        raise ApiError("workshop_limit_reached", 409)
                    intent_id = uuid.uuid4().hex
                    connection.execute(
                        "INSERT INTO workshop_intents "
                        "(id,printer_id,actor_id,request_key,action,printer_revision,"
                        "service_revision,job_revision,material_revision,safety_revision,"
                        "state,effect,created_at,envelope_tag) "
                        "VALUES(?,?,?,?,?,?,?,?,?,?,'recorded','notDispatched',?,'')",
                        (
                            intent_id, printer_id, actor.id, command.requestKey,
                            command.action, command.expectedPrinterRevision,
                            command.expectedServiceRevision, command.expectedJobRevision,
                            command.expectedMaterialRevision, command.expectedSafetyRevision,
                            now,
                        ),
                    )
                    saved = connection.execute(
                        "SELECT * FROM workshop_intents WHERE id=?", (intent_id,)
                    ).fetchone()
                    tag = self._intent_tag(saved)
                    connection.execute(
                        "UPDATE workshop_intents SET envelope_tag=? WHERE id=?",
                        (tag, intent_id),
                    )
                    saved = connection.execute(
                        "SELECT * FROM workshop_intents WHERE id=?", (intent_id,)
                    ).fetchone()
                    return {"receipt": self._public_intent(saved)}
        except ApiError:
            raise
        except (ValueError, sqlite3.Error):
            raise ApiError("workshop_storage_unavailable", 503) from None

    def intents(self, actor, core_id, home_id, printer_id, limit):
        if type(limit) is not int or not 1 <= limit <= 100:
            raise ApiError("invalid_request", 400)
        try:
            with self._transaction(actor, core_id, home_id) as connection:
                connection.execute("BEGIN")
                self._actor(connection, actor)
                self._printer(connection, printer_id)
                rows = connection.execute(
                    "SELECT * FROM workshop_intents WHERE printer_id=? "
                    "ORDER BY sequence DESC LIMIT ?",
                    (printer_id, limit),
                ).fetchall()
                return {"schemaVersion": 1, "intents": [
                    self._public_intent(row) for row in reversed(rows)
                ]}
        except ApiError:
            raise
        except (ValueError, sqlite3.Error):
            raise ApiError("workshop_storage_unavailable", 503) from None

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                printers = connection.execute(
                    "SELECT * FROM workshop_printers ORDER BY id"
                ).fetchall()
                intents = connection.execute(
                    "SELECT * FROM workshop_intents ORDER BY sequence"
                ).fetchall()
                if len(printers) > schema.MAX_PRINTERS or len(intents) > schema.MAX_INTENTS:
                    raise ValueError("workshop_limit")
                printer_ids = {row["id"] for row in printers}
                for row in printers:
                    self._validate_printer(row)
                for row in intents:
                    self._validate_intent(row)
                    if row["printer_id"] not in printer_ids:
                        raise ValueError("orphan_workshop_intent")
        except (ValueError, sqlite3.Error):
            raise StartupError("workshop_storage_invalid") from None
