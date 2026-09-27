import hashlib
import hmac
import json
import platform
import sqlite3
import threading
from pathlib import Path

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from .engine import VisualSensorEngine
from .http_models import (
    ConfigureVisualSensorRule,
    SubmitVisualSensorObservation,
    VisualEngineCapability,
    VisualSensorSummary,
)
from .models import CameraVisualAuthority, VisualSensorReading, VisualSensorRule

MAX_RULES = 64
MAX_RUNTIME_BYTES = 8 * 1024 * 1024
MAX_CLOCK_SKEW_MS = 5_000
MAX_OBSERVATION_AGE_MS = 5 * 60_000


def _canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


class CameraVisualSensorService:
    """Metadata-only visual sensor runtime; images never cross this boundary."""

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings, self._key = db, auth, settings, key
        self.scope = HomeScope.model_validate(context.model_dump())
        self._lock = threading.RLock()
        self._authorities = {}
        self._rules = {}
        self._runtime_capability = None
        self._engine = VisualSensorEngine(
            authorityResolver=lambda account_id: self._authorities.get(account_id),
            ruleResolver=lambda rule_id: self._rules.get(rule_id),
            auditKey=key,
        )

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    def _actor(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT role,disabled,must_change_password,revision FROM users WHERE id=?",
            (actor.id,),
        ).fetchone()
        if (
            row is None
            or row["disabled"]
            or row["must_change_password"]
            or row["role"] != "admin"
        ):
            raise ApiError("forbidden", 403)
        return row

    def _tag(self, row):
        values = [
            self.scope.coreId,
            self.scope.homeId,
            row["id"],
            row["revision"],
            row["rule_json"],
            row["actor_id"],
            row["family_id"],
            row["updated_at"],
        ]
        return hmac.new(
            self._key,
            b"larenor-camera-visual-rule-v1\0" + _canonical(values).encode(),
            hashlib.sha256,
        ).hexdigest()

    def _runtime_tag(self, runtime_json, capability_json, updated_at):
        return hmac.new(
            self._key,
            b"larenor-camera-visual-runtime-v1\0"
            + _canonical(
                [self.scope.coreId, self.scope.homeId, runtime_json,
                 capability_json, updated_at]
            ).encode(),
            hashlib.sha256,
        ).hexdigest()

    def _rule(self, row):
        if not hmac.compare_digest(row["envelope_tag"], self._tag(row)):
            raise ValueError("invalid_visual_rule_tag")
        rule = VisualSensorRule.model_validate_json(row["rule_json"])
        if rule.ruleId != row["id"] or rule.ruleRevision != row["revision"]:
            raise ValueError("invalid_visual_rule_identity")
        return rule

    def _runtime_row(self, connection):
        rows = connection.execute(
            "SELECT * FROM camera_visual_sensor_runtime ORDER BY singleton LIMIT 2"
        ).fetchall()
        if len(rows) > 1:
            raise ValueError("duplicate_visual_runtime")
        return None if not rows else rows[0]

    def _load_runtime(self, row):
        if row is None:
            return
        runtime_json, capability_json = row["runtime_json"], row["capability_json"]
        if (
            not isinstance(runtime_json, str)
            or not isinstance(capability_json, str)
            or len(runtime_json.encode()) > MAX_RUNTIME_BYTES
            or len(capability_json.encode()) > 4_096
            or not hmac.compare_digest(
                row["envelope_tag"],
                self._runtime_tag(runtime_json, capability_json, row["updated_at"]),
            )
        ):
            raise ValueError("invalid_visual_runtime")
        self._engine.restore(json.loads(runtime_json))
        self._runtime_capability = VisualEngineCapability.model_validate_json(
            capability_json
        )

    def _persist_runtime(self, connection, capability):
        runtime_json = _canonical(self._engine.checkpoint())
        capability_json = capability.model_dump_json()
        if len(runtime_json.encode()) > MAX_RUNTIME_BYTES:
            raise ApiError("bounded_visual_sensor_limit_reached", 409)
        updated_at = float(self.settings.clock())
        tag = self._runtime_tag(runtime_json, capability_json, updated_at)
        connection.execute(
            "INSERT INTO camera_visual_sensor_runtime VALUES(1,?,?,?,?) "
            "ON CONFLICT(singleton) DO UPDATE SET runtime_json=excluded.runtime_json,"
            "capability_json=excluded.capability_json,envelope_tag=excluded.envelope_tag,"
            "updated_at=excluded.updated_at",
            (runtime_json, capability_json, tag, updated_at),
        )
        self._runtime_capability = capability

    def validate_storage(self):
        try:
            with self._lock, self.db.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM camera_visual_sensor_rules ORDER BY id LIMIT ?",
                    (MAX_RULES + 1,),
                ).fetchall()
                if len(rows) > MAX_RULES:
                    raise ValueError("visual_rule_limit")
                self._rules = {row["id"]: self._rule(row) for row in rows}
                self._load_runtime(self._runtime_row(connection))
        except (sqlite3.Error, ValueError, TypeError, json.JSONDecodeError):
            raise StartupError("camera_visual_sensor_storage_invalid") from None

    @staticmethod
    def capability():
        machine = platform.machine().lower()
        architecture = (
            "arm64" if machine in {"arm64", "aarch64"}
            else "amd64" if machine in {"amd64", "x86_64"}
            else "other"
        )
        flags = None
        path = Path("/proc/cpuinfo")
        try:
            if path.is_file() and path.stat().st_size <= 2 * 1024 * 1024:
                text = path.read_text(encoding="ascii", errors="ignore").lower()
                flags = set(text.replace("\n", " ").split())
        except OSError:
            flags = None
        if architecture == "arm64":
            avx = avx2 = "not_applicable"
            reason = "arm64_unverified"
        elif architecture == "amd64" and flags is not None:
            avx = "supported" if "avx" in flags else "unsupported"
            avx2 = "supported" if "avx2" in flags else "unsupported"
            reason = (
                "detector_worker_not_configured"
                if avx == avx2 == "supported"
                else "cpu_requirements_unmet"
            )
        else:
            avx = avx2 = "unknown"
            reason = "capability_unverified"
        return VisualEngineCapability(
            schemaVersion=1,
            architecture=architecture,
            avx=avx,
            avx2=avx2,
            arm64=architecture == "arm64",
            detectorState="unavailable",
            trainingSupported=False,
            inferenceSupported=False,
            reason=reason,
        )

    @staticmethod
    def _summary(rule, reading=None, *, now_ms=0):
        if reading is None or reading.ruleRevision != rule.ruleRevision:
            return VisualSensorSummary(
                schemaVersion=2, ruleId=rule.ruleId,
                ruleRevision=rule.ruleRevision, cameraId=rule.cameraId,
                pipelineId=rule.pipelineId,
                pipelineRevision=rule.pipelineRevision, modelId=rule.modelId,
                modelRevision=rule.modelRevision, label=rule.label,
                state="unknown", status="unavailable",
                reason="no_trusted_frame", observedAtMs=None, staleAtMs=None,
                evidenceDigest=None, confidenceBps=0, count=0,
                automationEligible=False, accessControlEligible=False,
            )
        stale_at = reading.observedAtMs + rule.evidenceRetentionMs
        if now_ms >= stale_at:
            state, status, reason, automation = (
                "unknown", "degraded", "stale_frame", False
            )
        elif reading.frameStatus != "complete":
            state, status, reason, automation = (
                "unknown", "degraded", f"{reading.frameStatus}_frame", False
            )
        elif reading.status == "degraded":
            state, status, reason, automation = (
                "unknown", "degraded", "provider_degraded", False
            )
        else:
            state, status, reason, automation = (
                reading.state, "ready", "trusted_frame",
                reading.automationEligible,
            )
        return VisualSensorSummary(
            schemaVersion=2, ruleId=rule.ruleId,
            ruleRevision=rule.ruleRevision, cameraId=rule.cameraId,
            pipelineId=rule.pipelineId,
            pipelineRevision=rule.pipelineRevision, modelId=rule.modelId,
            modelRevision=rule.modelRevision, label=rule.label,
            state=state, status=status, reason=reason,
            observedAtMs=reading.observedAtMs, staleAtMs=stale_at,
            evidenceDigest=reading.evidenceDigest,
            confidenceBps=reading.confidenceBps, count=reading.count,
            automationEligible=automation, accessControlEligible=False,
        )

    def _readings(self):
        return {
            item["ruleId"]: (
                None if item["lastReading"] is None
                else VisualSensorReading.model_validate(item["lastReading"])
            )
            for item in self._engine.checkpoint()["states"]
        }

    def _effective_capability(self, readings, now_ms):
        capability = self._runtime_capability
        if capability is None:
            return self.capability()
        fresh_until = max(
            (
                reading.observedAtMs + self._rules[rule_id].evidenceRetentionMs
                for rule_id, reading in readings.items()
                if reading is not None and rule_id in self._rules
            ),
            default=0,
        )
        if now_ms < fresh_until:
            return capability
        return capability.model_copy(
            update={"detectorState": "degraded", "reason": "worker_stale"}
        )

    def configure(self, actor, core_id, home_id, rule_id, value):
        body = ConfigureVisualSensorRule.model_validate(value)
        self._scope(core_id, home_id)
        if body.rule.ruleId != rule_id:
            raise ApiError("revision_conflict", 409)
        before = None
        previous_rules = dict(self._rules)
        try:
            with self._lock, self.db.transaction() as connection:
                self._actor(connection, actor)
                old = connection.execute(
                    "SELECT * FROM camera_visual_sensor_rules WHERE id=?", (rule_id,)
                ).fetchone()
                if old is not None:
                    self._rule(old)
                current = 0 if old is None else old["revision"]
                if (body.expectedRevision != current
                        or body.rule.ruleRevision != current + 1):
                    raise ApiError("revision_conflict", 409)
                if (old is None and connection.execute(
                    "SELECT COUNT(*) FROM camera_visual_sensor_rules"
                ).fetchone()[0] >= MAX_RULES):
                    raise ApiError("visual_sensor_limit_reached", 429)
                values = [rule_id, body.rule.ruleRevision,
                          body.rule.model_dump_json(), actor.id, actor.family_id,
                          float(self.settings.clock())]
                row = dict(zip(("id", "revision", "rule_json", "actor_id",
                                "family_id", "updated_at"), values))
                tag = self._tag(row)
                connection.execute(
                    "INSERT INTO camera_visual_sensor_rules VALUES(?,?,?,?,?,?,?) "
                    "ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,"
                    "rule_json=excluded.rule_json,actor_id=excluded.actor_id,"
                    "family_id=excluded.family_id,updated_at=excluded.updated_at,"
                    "envelope_tag=excluded.envelope_tag", (*values, tag))
                before = self._engine.checkpoint()
                self._engine.resetRule(rule_id)
                self._rules[rule_id] = body.rule
                if self._runtime_capability is not None:
                    self._persist_runtime(connection, self._runtime_capability)
                return {"schemaVersion": 2, "rule": self._summary(
                    body.rule, now_ms=int(self.settings.clock() * 1000))}
        except ApiError:
            if before is not None:
                self._engine.restore(before)
                self._rules = previous_rules
            raise
        except (sqlite3.Error, ValueError, TypeError):
            if before is not None:
                self._engine.restore(before)
                self._rules = previous_rules
            raise ApiError("visual_sensor_storage_unavailable", 503) from None

    def observe(self, actor, core_id, home_id, rule_id, value, *,
                cancelled=lambda: False):
        body = SubmitVisualSensorObservation.model_validate(value)
        self._scope(core_id, home_id)
        if cancelled():
            raise ApiError("request_cancelled", 408)
        before = None
        previous_capability = self._runtime_capability
        try:
            with self._lock, self.db.transaction() as connection:
                actor_row = self._actor(connection, actor)
                rows = connection.execute(
                    "SELECT * FROM camera_visual_sensor_rules ORDER BY id LIMIT ?",
                    (MAX_RULES + 1,),
                ).fetchall()
                if len(rows) > MAX_RULES:
                    raise ValueError("visual_rule_limit")
                rules = {row["id"]: self._rule(row) for row in rows}
                rule = rules.get(rule_id)
                if rule is None:
                    raise ApiError("not_found", 404)
                if body.expectedRuleRevision != rule.ruleRevision:
                    raise ApiError("revision_conflict", 409)
                now_ms = int(self.settings.clock() * 1000)
                maximum_age = min(rule.evidenceRetentionMs, MAX_OBSERVATION_AGE_MS)
                if (body.batch.capturedAtMs > now_ms + MAX_CLOCK_SKEW_MS
                        or now_ms - body.batch.capturedAtMs > maximum_age
                        or body.batch.evidence.expiresAtMs <= now_ms):
                    raise ApiError("visual_sensor_observation_stale", 409)
                authority = CameraVisualAuthority(
                    schemaVersion=1, coreId=self.scope.coreId,
                    homeId=self.scope.homeId, homeRevision=1,
                    accountId=actor.id, accountRevision=actor_row["revision"],
                    memberRevision=actor_row["revision"],
                    sessionFamilyId=actor.family_id, role="admin",
                    accessibleCameraIds=sorted(
                        {item.cameraId for item in rules.values()}),
                    active=True, canManageVisualSensors=True,
                )
                self._authorities[actor.id] = authority
                self._rules = rules
                before = self._engine.checkpoint()
                reading = self._engine.ingest(authority, rule, body.batch)
                if cancelled():
                    self._engine.restore(before)
                    raise ApiError("request_cancelled", 408)
                self._persist_runtime(connection, body.capability)
                return {"schemaVersion": 1, "reading": reading}
        except ApiError:
            if before is not None:
                self._engine.restore(before)
                self._runtime_capability = previous_capability
            raise
        except (sqlite3.Error, ValueError, TypeError):
            if before is not None:
                self._engine.restore(before)
                self._runtime_capability = previous_capability
            raise ApiError("visual_sensor_storage_unavailable", 503) from None

    def summary(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        try:
            with self._lock, self.db.connection() as connection:
                connection.execute("BEGIN")
                self._actor(connection, actor)
                rows = connection.execute(
                    "SELECT * FROM camera_visual_sensor_rules ORDER BY id LIMIT ?",
                    (MAX_RULES + 1,),
                ).fetchall()
                if len(rows) > MAX_RULES:
                    raise ValueError("visual_rule_limit")
                rules = [self._rule(row) for row in rows]
                self._rules = {rule.ruleId: rule for rule in rules}
                readings = self._readings()
                now_ms = int(self.settings.clock() * 1000)
                return {
                    "schemaVersion": 2, "scope": self.scope,
                    "capability": self._effective_capability(readings, now_ms),
                    "rules": [self._summary(
                        rule, readings.get(rule.ruleId), now_ms=now_ms)
                        for rule in rules],
                }
        except ApiError:
            raise
        except (sqlite3.Error, ValueError, TypeError):
            raise ApiError("visual_sensor_storage_unavailable", 503) from None
