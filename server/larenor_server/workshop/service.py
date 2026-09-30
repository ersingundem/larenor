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
from ..services.service import MAX_SERVICES
from . import schema
from .models import (
    ConfirmIntent,
    PreviewIntent,
    RegisterPrinter,
    RegisterPrinterFromService,
    TemperatureStateView,
    UpdatePrinterState,
    WorkshopCommand,
    WorkshopCommandReadback,
    WorkshopProviderCapability,
    WorkshopProviderObservation,
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
    """Printer authority with confirmed commands and exact provider readback."""

    def __init__(self, db, auth, settings, key, context, services, provider=None):
        self.db, self.auth, self.settings = db, auth, settings
        self._key, self.services = key, services
        self.provider = provider
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

    @staticmethod
    def _temperatures_json(heaters):
        return json.dumps(
            [heater.model_dump(mode="json") for heater in heaters],
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )

    @staticmethod
    def _temperature_state(row):
        try:
            raw = json.loads(row["temperatures_json"])
            value = TemperatureStateView.model_validate({
                "revision": row["temperature_revision"],
                "heaters": raw,
            })
        except Exception:
            raise ValueError("invalid_workshop_temperature") from None
        if WorkshopService._temperatures_json(value.heaters) != row["temperatures_json"]:
            raise ValueError("invalid_workshop_temperature")
        return value

    def _printer_tag(self, row, *, include_temperature=True):
        fields = [
            self.scope.coreId, self.scope.homeId, row["id"], row["owner_id"],
            row["family_id"], row["revision"], row["service_id"],
            row["service_revision"], row["name"], row["job_revision"],
            row["job_id"], row["job_state"], row["progress_permille"],
            row["remaining_seconds"], row["material_revision"],
            row["material_kind"], row["remaining_grams"],
            row["safety_revision"], row["connectivity"], row["thermal"],
            row["filament"], row["door"], row["emergency"],
            row["observed_at"],
        ]
        if include_temperature:
            fields.extend((row["temperature_revision"], row["temperatures_json"]))
        fields.append(row["updated_at"])
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

    def _effect_tag(self, row):
        fields = [
            self.scope.coreId, self.scope.homeId, row["intent_id"],
            row["command_id"], row["status"], row["code"],
            row["provider_revision"], row["readback_json"], row["created_at"],
        ]
        encoded = json.dumps(
            fields, ensure_ascii=False, separators=(",", ":"), allow_nan=False
        ).encode("utf-8")
        return hmac.new(
            self._key, b"larenor-workshop-effect-v1\0" + encoded,
            hashlib.sha256,
        ).hexdigest()

    def _validate_printer(self, row):
        temperature = self._temperature_state(row) if row is not None else None
        current_tag = (
            row is not None
            and isinstance(row["envelope_tag"], str)
            and hmac.compare_digest(row["envelope_tag"], self._printer_tag(row))
        )
        legacy_tag = (
            temperature is not None
            and temperature.revision == 1
            and not temperature.heaters
            and isinstance(row["envelope_tag"], str)
            and hmac.compare_digest(
                row["envelope_tag"],
                self._printer_tag(row, include_temperature=False),
            )
        )
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
                       "temperature_revision",
                   ))
            or row["job_state"] not in {"idle", "printing", "paused", "completed", "error"}
            or (row["job_state"] == "idle") != (row["job_id"] is None)
            or type(row["progress_permille"]) is not int
            or not 0 <= row["progress_permille"] <= 1000
            or row["remaining_seconds"] is not None
            and (type(row["remaining_seconds"]) is not int
                 or not 0 <= row["remaining_seconds"] <= 31_536_000)
            or row["material_kind"] not in {
                "pla", "petg", "abs", "tpu", "asa", "other", "unknown"
            }
            or (row["material_kind"] == "unknown") !=
            (row["remaining_grams"] is None)
            or row["remaining_grams"] is not None
            and (not self._finite(row["remaining_grams"])
                 or not 0 <= row["remaining_grams"] <= 100_000)
            or row["connectivity"] not in {"online", "offline"}
            or row["thermal"] not in {"normal", "warning", "runaway", "unknown"}
            or row["filament"] not in {"available", "low", "runout", "unknown"}
            or row["door"] not in {"closed", "open", "unknown"}
            or row["emergency"] not in {"clear", "triggered", "unknown"}
            or not self._finite(row["observed_at"])
            or not self._finite(row["updated_at"])
            or row["observed_at"] > row["updated_at"] + 5
            or _DIGEST.fullmatch(row["envelope_tag"]) is None
            or not (current_tag or legacy_tag)
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

    def _validate_effect(self, row):
        if (
            row is None
            or any(not isinstance(row[name], str) for name in (
                "intent_id", "command_id", "status", "code", "envelope_tag",
            ))
            or any(_IDENTITY.fullmatch(row[name]) is None for name in (
                "intent_id", "command_id",
            ))
            or row["status"] not in {"applied", "unknown"}
            or row["code"] not in {
                "applied", "readback_mismatch", "worker_ack_unknown",
            }
            or type(row["provider_revision"]) is not int
            or not 1 <= row["provider_revision"] <= 2**63 - 1
            or row["readback_json"] is not None
            and not isinstance(row["readback_json"], str)
            or not self._finite(row["created_at"])
            or _DIGEST.fullmatch(row["envelope_tag"]) is None
            or not hmac.compare_digest(row["envelope_tag"], self._effect_tag(row))
        ):
            raise ValueError("invalid_workshop_effect")
        readback = None
        if row["readback_json"] is not None:
            readback = WorkshopCommandReadback.model_validate_json(
                row["readback_json"]
            )
        if (row["status"] == "applied") != (row["code"] == "applied"):
            raise ValueError("invalid_workshop_effect")
        if row["code"] == "worker_ack_unknown" and readback is not None:
            raise ValueError("invalid_workshop_effect")
        return row, readback

    def _binding(self, connection, service_id, revision):
        try:
            return self.services._workshop_connection(
                connection, service_id, revision
            )
        except ApiError:
            raise ApiError("workshop_binding_changed", 409) from None

    def _observation(self, actor, binding, row, now):
        if not getattr(self.provider, "exact_observations", False):
            return None
        resolver = getattr(self.provider, "observe", None)
        if not callable(resolver):
            raise ApiError("workshop_provider_unavailable", 503)
        try:
            observation = WorkshopProviderObservation.model_validate(
                resolver(actor, binding, row["id"])
            )
        except ApiError:
            raise
        except Exception:
            raise ApiError("workshop_provider_unavailable", 503) from None
        if (
            observation.observedAt > now + 5
            or now - observation.observedAt > _SAFETY_TTL_SECONDS
        ):
            raise ApiError("workshop_provider_unverified", 409)
        return observation

    def _apply_observation(self, connection, row, observation, now):
        if observation is None:
            return row
        temperature_json = self._temperatures_json(observation.temperatures)
        fields = {
            "job_id": observation.jobId,
            "job_state": observation.jobState,
            "progress_permille": observation.progressPermille,
            "remaining_seconds": observation.remainingSeconds,
            "connectivity": observation.connectivity,
            "thermal": observation.thermal,
            "filament": observation.filament,
            "door": observation.door,
            "emergency": observation.emergency,
            "temperatures_json": temperature_json,
        }
        job_changed = any(row[name] != fields[name] for name in (
            "job_id", "job_state", "progress_permille", "remaining_seconds",
        ))
        safety_changed = any(row[name] != fields[name] for name in (
            "connectivity", "thermal", "filament", "door", "emergency",
        ))
        temperature_changed = row["temperatures_json"] != temperature_json
        # Refreshing the freshness timestamp for every HTTP read would make a
        # reviewed preview stale before its confirmation.  Renew it only when
        # state changed or half of the safety TTL has elapsed.
        renew = (
            job_changed or safety_changed or temperature_changed
            or observation.observedAt - row["observed_at"] >= _SAFETY_TTL_SECONDS / 2
        )
        if not renew:
            return row
        changed = dict(row)
        changed.update(fields)
        changed.update(
            revision=row["revision"] + 1,
            job_revision=row["job_revision"] + (1 if job_changed else 0),
            safety_revision=row["safety_revision"] + 1,
            temperature_revision=(
                row["temperature_revision"] + (1 if temperature_changed else 0)
            ),
            observed_at=observation.observedAt,
            updated_at=now,
        )
        changed["envelope_tag"] = self._printer_tag(changed)
        result = connection.execute(
            "UPDATE workshop_printers SET revision=?,job_revision=?,job_id=?,job_state=?,"
            "progress_permille=?,remaining_seconds=?,safety_revision=?,connectivity=?,"
            "thermal=?,filament=?,door=?,emergency=?,observed_at=?,updated_at=?,"
            "temperature_revision=?,temperatures_json=?,envelope_tag=? "
            "WHERE id=? AND revision=?",
            (
                changed["revision"], changed["job_revision"], changed["job_id"],
                changed["job_state"], changed["progress_permille"],
                changed["remaining_seconds"], changed["safety_revision"],
                changed["connectivity"], changed["thermal"], changed["filament"],
                changed["door"], changed["emergency"], changed["observed_at"],
                changed["updated_at"], changed["temperature_revision"],
                changed["temperatures_json"], changed["envelope_tag"], row["id"],
                row["revision"],
            ),
        )
        if result.rowcount != 1:
            raise ApiError("workshop_state_changed", 409)
        return self._printer(connection, row["id"])

    def _apply_authority_observation(self, connection, row, observation, now):
        if observation is None:
            return row
        authority = {
            "job_id": observation.jobId,
            "job_state": observation.jobState,
            "connectivity": observation.connectivity,
            "thermal": observation.thermal,
            "filament": observation.filament,
            "door": observation.door,
            "emergency": observation.emergency,
        }
        if all(row[name] == value for name, value in authority.items()):
            # Progress and ETA naturally move between preview and confirmation.
            # They are projected by list/readback, but cannot identify a job.
            return row
        return self._apply_observation(connection, row, observation, now)

    def _capability(self, actor, binding, printer_id, action, now,
                    observation=None):
        if self.provider is None:
            raise ApiError("workshop_provider_unavailable", 503)
        resolver = getattr(self.provider, "capability", None)
        executor = getattr(self.provider, "execute", None)
        if not callable(resolver) or not callable(executor):
            raise ApiError("workshop_provider_unavailable", 503)
        try:
            capability = WorkshopProviderCapability.model_validate(
                ({
                    "schemaVersion": 1,
                    "providerRevision": observation.providerRevision,
                    "supportedActions": observation.supportedActions,
                    "observedAt": observation.observedAt,
                } if observation is not None else
                 resolver(actor, binding, printer_id))
            )
        except ApiError:
            raise
        except Exception:
            raise ApiError("workshop_provider_unavailable", 503) from None
        if (
            capability.observedAt > now + 5
            or now - capability.observedAt > _SAFETY_TTL_SECONDS
            or action not in capability.supportedActions
        ):
            raise ApiError("workshop_provider_unverified", 409)
        return capability

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
        if (
            not self._fresh(row, now)
            or row["connectivity"] != "online"
            or row["job_id"] is None
        ):
            return []
        if row["job_state"] == "printing":
            return ["pause", "cancel"]
        if row["job_state"] == "paused":
            return ["cancel"]
        return []

    def _public_printer(self, row, now, provider_actions=None):
        self._validate_printer(row)
        temperature = self._temperature_state(row)
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
            "temperature": temperature.model_dump(mode="json"),
            "availableActions": (
                [action for action in self._available_actions(row, now)
                 if provider_actions is None or action in provider_actions]
                if callable(getattr(self.provider, "capability", None))
                and callable(getattr(self.provider, "execute", None))
                and (provider_actions is not None
                     or not getattr(self.provider, "exact_observations", False))
                else []
            ),
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

    def catalog(self, actor, core_id, home_id):
        try:
            with self._transaction(actor, core_id, home_id) as connection:
                self._actor(connection, actor)
                rows = connection.execute(
                    "SELECT * FROM service_connections ORDER BY id LIMIT ?",
                    (MAX_SERVICES + 1,),
                ).fetchall()
                if len(rows) > MAX_SERVICES:
                    raise ValueError("workshop_service_limit")
                services = []
                for row in rows:
                    record = self.services._decode(row)
                    if (
                        record["kind"] in {"octoprint", "moonraker"}
                        and set(record["credentials"]) == {"apiKey"}
                        and record["verification"]["state"] == "authenticated"
                    ):
                        services.append({
                            "id": row["id"],
                            "revision": row["revision"],
                            "name": record["name"],
                            "kind": record["kind"],
                        })
                services.sort(key=lambda item: (item["name"].casefold(), item["id"]))
                return {"schemaVersion": 1, "services": services}
        except ApiError:
            raise
        except (ValueError, sqlite3.Error):
            raise ApiError("workshop_storage_unavailable", 503) from None

    def _registration_replay(self, row, body, now):
        if row is None:
            return None
        self._validate_printer(row)
        if (
            row["name"] != body.name
            or row["service_id"] != body.serviceId
            or row["service_revision"] != body.expectedServiceRevision
        ):
            raise ApiError("workshop_registration_replay", 409)
        return self._public_printer(row, now)

    def register_from_service(self, actor, core_id, home_id, value):
        body = RegisterPrinterFromService.model_validate(value)
        now = float(self.settings.clock())
        try:
            with self._transaction(actor, core_id, home_id) as connection:
                self._actor(connection, actor)
                old = connection.execute(
                    "SELECT * FROM workshop_printers WHERE id=?",
                    (body.registrationId,),
                ).fetchone()
                replay = self._registration_replay(old, body, now)
                if replay is not None:
                    return replay
                binding = self._binding(
                    connection, body.serviceId, body.expectedServiceRevision
                )

            observation = self._observation(
                actor, binding, {"id": body.registrationId}, now
            )
            now = float(self.settings.clock())
            if (
                observation.observedAt > now + 5
                or now - observation.observedAt > _SAFETY_TTL_SECONDS
            ):
                raise ApiError("workshop_provider_unverified", 409)

            with self._transaction(actor, core_id, home_id, write=True) as connection:
                self._actor(connection, actor)
                old = connection.execute(
                    "SELECT * FROM workshop_printers WHERE id=?",
                    (body.registrationId,),
                ).fetchone()
                replay = self._registration_replay(old, body, now)
                if replay is not None:
                    return replay
                self._binding(
                    connection, body.serviceId, body.expectedServiceRevision
                )
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
                    "job_id": observation.jobId,
                    "job_state": observation.jobState,
                    "progress_permille": observation.progressPermille,
                    "remaining_seconds": observation.remainingSeconds,
                    "material_revision": 1,
                    "material_kind": observation.materialKind,
                    "remaining_grams": observation.remainingGrams,
                    "safety_revision": 1,
                    "connectivity": observation.connectivity,
                    "thermal": observation.thermal,
                    "filament": observation.filament,
                    "door": observation.door,
                    "emergency": observation.emergency,
                    "observed_at": observation.observedAt,
                    "temperature_revision": 1,
                    "temperatures_json": self._temperatures_json(
                        observation.temperatures
                    ),
                    "updated_at": now,
                }
                row["envelope_tag"] = self._printer_tag(row)
                columns = (
                    "id", "owner_id", "family_id", "revision", "service_id",
                    "service_revision", "name", "job_revision", "job_id",
                    "job_state", "progress_permille", "remaining_seconds",
                    "material_revision", "material_kind", "remaining_grams",
                    "safety_revision", "connectivity", "thermal", "filament",
                    "door", "emergency", "observed_at", "temperature_revision",
                    "temperatures_json", "updated_at", "envelope_tag",
                )
                connection.execute(
                    "INSERT INTO workshop_printers VALUES("
                    + ",".join("?" for _ in columns)
                    + ")",
                    tuple(row[name] for name in columns),
                )
                saved = self._printer(connection, body.registrationId)
                return self._public_printer(
                    saved, now, observation.supportedActions
                )
        except ApiError:
            raise
        except (ValueError, sqlite3.Error):
            raise ApiError("workshop_storage_unavailable", 503) from None

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
                    "temperature_revision": 1,
                    "temperatures_json": "[]",
                    **requested,
                    "updated_at": now,
                }
                row["envelope_tag"] = self._printer_tag(row)
                connection.execute(
                    "INSERT INTO workshop_printers VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    tuple(row[name] for name in (
                        "id", "owner_id", "family_id", "revision", "service_id",
                        "service_revision", "name", "job_revision", "job_id", "job_state",
                        "progress_permille", "remaining_seconds", "material_revision",
                        "material_kind", "remaining_grams", "safety_revision", "connectivity",
                        "thermal", "filament", "door", "emergency", "observed_at",
                        "temperature_revision", "temperatures_json", "updated_at",
                        "envelope_tag",
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
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                self._actor(connection, actor)
                rows = connection.execute(
                    "SELECT * FROM workshop_printers ORDER BY name COLLATE NOCASE,id LIMIT ?",
                    (schema.MAX_PRINTERS + 1,),
                ).fetchall()
                if len(rows) > schema.MAX_PRINTERS:
                    raise ValueError("workshop_printer_limit")
                printers = []
                for original in rows:
                    row, actions = original, None
                    if getattr(self.provider, "exact_observations", False):
                        try:
                            binding = self._binding(
                                connection, row["service_id"], row["service_revision"]
                            )
                            observation = self._observation(
                                actor, binding, row, now
                            )
                            row = self._apply_observation(
                                connection, row, observation, now
                            )
                            actions = observation.supportedActions
                        except ApiError:
                            # Monitoring remains readable during an upstream
                            # outage, but no write capability is advertised.
                            row, actions = original, []
                    printers.append(
                        self._public_printer(row, now, actions)["printer"]
                    )
                return {"schemaVersion": 1, "printers": printers}
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
                with self._transaction(actor, core_id, home_id, write=True) as connection:
                    self._actor(connection, actor)
                    row = self._printer(
                        connection, printer_id, expected=body.expectedPrinterRevision
                    )
                    binding = self._binding(
                        connection, row["service_id"], body.expectedServiceRevision
                    )
                    self._assert_commandable(row, body, now)
                    observation = self._observation(actor, binding, row, now)
                    row = self._apply_authority_observation(
                        connection, row, observation, now
                    )
                    self._assert_commandable(row, body, now)
                    self._capability(
                        actor, binding, printer_id, body.action, now, observation
                    )
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

    def _public_intent(self, row, effect=None):
        self._validate_intent(row)
        value = {
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
        if effect is not None:
            effect, readback = self._validate_effect(effect)
            if effect["intent_id"] != row["id"]:
                raise ValueError("invalid_workshop_effect")
            value["schemaVersion"] = 2
            value["effect"] = effect["status"]
            value["execution"] = {
                "commandId": effect["command_id"],
                "status": effect["status"],
                "code": effect["code"],
                "providerRevision": effect["provider_revision"],
                "readback": (
                    None if readback is None else readback.model_dump(mode="json")
                ),
            }
        return value

    def _effect(self, connection, intent_id):
        row = connection.execute(
            "SELECT * FROM workshop_effects WHERE intent_id=?", (intent_id,)
        ).fetchone()
        if row is not None:
            self._validate_effect(row)
        return row

    def _insert_pending_effect(self, connection, intent_id, command, now):
        connection.execute(
            "INSERT INTO workshop_effects "
            "(intent_id,command_id,status,code,provider_revision,readback_json,"
            "created_at,envelope_tag) VALUES(?,?,'unknown','worker_ack_unknown',?,NULL,?,'')",
            (intent_id, command.commandId, command.providerRevision, now),
        )
        row = connection.execute(
            "SELECT * FROM workshop_effects WHERE intent_id=?", (intent_id,)
        ).fetchone()
        if row is None or row["envelope_tag"] != "":
            raise ValueError("invalid_workshop_effect")

    def _seal_pending_effect(self, connection, intent_id):
        row = connection.execute(
            "SELECT * FROM workshop_effects WHERE intent_id=?", (intent_id,)
        ).fetchone()
        if row is None or row["envelope_tag"] != "":
            raise ValueError("invalid_workshop_effect")
        connection.execute(
            "UPDATE workshop_effects SET envelope_tag=? WHERE intent_id=?",
            (self._effect_tag(row), intent_id),
        )
        return self._effect(connection, intent_id)

    def _finish_effect(self, intent_id, command, raw_readback):
        now = float(self.settings.clock())
        readback = None
        status, code = "unknown", "worker_ack_unknown"
        if raw_readback is not None:
            try:
                readback = WorkshopCommandReadback.model_validate(raw_readback)
                expected_state = (
                    readback.jobState == "paused"
                    if command.action == "pause"
                    else readback.jobState in {"idle", "completed"}
                )
                exact = all((
                    readback.commandId == command.commandId,
                    readback.printerId == command.printerId,
                    readback.action == command.action,
                    readback.providerRevision == command.providerRevision,
                    readback.jobRevision > command.expectedJobRevision,
                    readback.connectivity == "online",
                    readback.observedAt <= now + 5,
                    now - readback.observedAt <= _SAFETY_TTL_SECONDS,
                    expected_state,
                ))
                status, code = (
                    ("applied", "applied")
                    if exact else ("unknown", "readback_mismatch")
                )
            except Exception:
                readback = None
                status, code = "unknown", "worker_ack_unknown"
        encoded = (
            None if readback is None else json.dumps(
                readback.model_dump(mode="json"),
                sort_keys=True, separators=(",", ":"), allow_nan=False,
            )
        )
        with self.db.transaction() as connection:
            row = self._effect(connection, intent_id)
            if row is None or row["command_id"] != command.commandId:
                raise ApiError("workshop_storage_unavailable", 503)
            changed = dict(row)
            changed.update(status=status, code=code, readback_json=encoded)
            connection.execute(
                "UPDATE workshop_effects SET status=?,code=?,readback_json=?,"
                "envelope_tag=? WHERE intent_id=? AND command_id=?",
                (
                    status, code, encoded, self._effect_tag(changed), intent_id,
                    command.commandId,
                ),
            )
            return self._effect(connection, intent_id)

    def _provider_readback(self, command, raw):
        if not getattr(self.provider, "exact_observations", False):
            return raw
        try:
            if (
                type(raw) is not dict
                or set(raw) != {
                    "schemaVersion", "commandId", "printerId", "action",
                    "providerRevision", "observation",
                }
                or raw["schemaVersion"] != 1
                or raw["commandId"] != command.commandId
                or raw["printerId"] != command.printerId
                or raw["action"] != command.action
                or raw["providerRevision"] != command.providerRevision
            ):
                return None
            observation = WorkshopProviderObservation.model_validate(
                raw["observation"]
            )
            now = float(self.settings.clock())
            if (
                observation.observedAt > now + 5
                or now - observation.observedAt > _SAFETY_TTL_SECONDS
            ):
                return None
            with self.db.transaction() as connection:
                row = self._printer(connection, command.printerId)
                if any((
                    row["service_id"] != command.serviceId,
                    row["service_revision"] != command.serviceRevision,
                    row["job_revision"] != command.expectedJobRevision,
                    row["job_id"] != command.expectedJobId,
                )):
                    return None
                saved = self._apply_observation(
                    connection, row, observation, now
                )
            return {
                "schemaVersion": 1,
                "commandId": command.commandId,
                "printerId": command.printerId,
                "action": command.action,
                "providerRevision": command.providerRevision,
                "jobRevision": saved["job_revision"],
                "jobState": saved["job_state"],
                "connectivity": saved["connectivity"],
                "observedAt": saved["observed_at"],
            }
        except Exception:
            # The command already left the process.  A malformed or stale
            # readback is unknown and must never trigger an implicit retry.
            return None

    def _dispatch(self, actor, binding, intent, command):
        raw_readback = None
        try:
            raw_readback = self.provider.execute(
                actor, binding, command.model_dump(mode="json")
            )
            raw_readback = self._provider_readback(command, raw_readback)
        except Exception:
            # The command may have reached the printer. Never retry implicitly.
            raw_readback = None
        effect = self._finish_effect(intent["id"], command, raw_readback)
        return {"receipt": self._public_intent(intent, effect)}

    def confirm(self, actor, core_id, home_id, printer_id, preview_id, value):
        body = ConfirmIntent.model_validate(value)
        now = float(self.settings.clock())
        dispatch = None
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
                command_body = PreviewIntent.model_validate(pending.body)
                if not hmac.compare_digest(
                    pending.request_hash, self._request_hash(command_body)
                ):
                    raise ApiError("workshop_preview_invalid", 409)
                with self._transaction(actor, core_id, home_id, write=True) as connection:
                    self._actor(connection, actor)
                    old = connection.execute(
                        "SELECT * FROM workshop_intents WHERE printer_id=? AND request_key=?",
                        (printer_id, command_body.requestKey),
                    ).fetchone()
                    if old is not None:
                        self._validate_intent(old)
                        if not self._intent_matches(old, command_body):
                            raise ApiError("workshop_intent_conflict", 409)
                        effect = self._effect(connection, old["id"])
                        # A retained result is authoritative after a lost ACK. A
                        # legacy not-dispatched receipt is never upgraded by retry.
                        return {"receipt": self._public_intent(old, effect)}
                    row = self._printer(
                        connection, printer_id,
                        expected=command_body.expectedPrinterRevision,
                    )
                    binding = self._binding(
                        connection, row["service_id"],
                        command_body.expectedServiceRevision,
                    )
                    self._assert_commandable(row, command_body, now)
                    observation = self._observation(actor, binding, row, now)
                    row = self._apply_authority_observation(
                        connection, row, observation, now
                    )
                    self._assert_commandable(row, command_body, now)
                    capability = self._capability(
                        actor, binding, printer_id, command_body.action, now,
                        observation,
                    )
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
                            intent_id, printer_id, actor.id, command_body.requestKey,
                            command_body.action, command_body.expectedPrinterRevision,
                            command_body.expectedServiceRevision,
                            command_body.expectedJobRevision,
                            command_body.expectedMaterialRevision,
                            command_body.expectedSafetyRevision, now,
                        ),
                    )
                    saved = connection.execute(
                        "SELECT * FROM workshop_intents WHERE id=?", (intent_id,)
                    ).fetchone()
                    connection.execute(
                        "UPDATE workshop_intents SET envelope_tag=? WHERE id=?",
                        (self._intent_tag(saved), intent_id),
                    )
                    saved = connection.execute(
                        "SELECT * FROM workshop_intents WHERE id=?", (intent_id,)
                    ).fetchone()
                    command = WorkshopCommand(
                        schemaVersion=1,
                        commandId=uuid.uuid4().hex,
                        actorId=actor.id,
                        printerId=printer_id,
                        serviceId=row["service_id"],
                        serviceRevision=command_body.expectedServiceRevision,
                        providerRevision=capability.providerRevision,
                        expectedJobRevision=command_body.expectedJobRevision,
                        expectedJobId=row["job_id"],
                        action=command_body.action,
                    )
                    self._insert_pending_effect(connection, intent_id, command, now)
                    effect = self._seal_pending_effect(connection, intent_id)
                    dispatch = (binding, saved, command)
                    response = {"receipt": self._public_intent(saved, effect)}
                if dispatch is not None:
                    binding, saved, command = dispatch
                    return self._dispatch(actor, binding, saved, command)
                return response
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
                    self._public_intent(
                        row, self._effect(connection, row["id"])
                    ) for row in reversed(rows)
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
                effects = connection.execute(
                    "SELECT * FROM workshop_effects ORDER BY intent_id"
                ).fetchall()
                if len(printers) > schema.MAX_PRINTERS or len(intents) > schema.MAX_INTENTS:
                    raise ValueError("workshop_limit")
                printer_ids = {row["id"] for row in printers}
                intent_ids = {row["id"] for row in intents}
                for row in printers:
                    self._validate_printer(row)
                for row in intents:
                    self._validate_intent(row)
                    if row["printer_id"] not in printer_ids:
                        raise ValueError("orphan_workshop_intent")
                for row in effects:
                    self._validate_effect(row)
                    if row["intent_id"] not in intent_ids:
                        raise ValueError("orphan_workshop_effect")
        except (ValueError, sqlite3.Error):
            raise StartupError("workshop_storage_invalid") from None
