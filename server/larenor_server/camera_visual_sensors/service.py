import hashlib
import hmac
import json
import platform
import sqlite3
from pathlib import Path

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from .http_models import (
    ConfigureVisualSensorRule,
    VisualEngineCapability,
    VisualSensorSummary,
)
from .models import VisualSensorRule

MAX_RULES = 64


def _canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


class CameraVisualSensorService:
    """Durable rule registry; no frame ingestion or detector success is implied."""

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings, self._key = db, auth, settings, key
        self.scope = HomeScope.model_validate(context.model_dump())

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    def _actor(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT role,disabled,must_change_password FROM users WHERE id=?",
            (actor.id,),
        ).fetchone()
        if (
            row is None
            or row["disabled"]
            or row["must_change_password"]
            or row["role"] != "admin"
        ):
            raise ApiError("forbidden", 403)

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

    def _rule(self, row):
        if not hmac.compare_digest(row["envelope_tag"], self._tag(row)):
            raise ValueError("invalid_visual_rule_tag")
        rule = VisualSensorRule.model_validate_json(row["rule_json"])
        if rule.ruleId != row["id"] or rule.ruleRevision != row["revision"]:
            raise ValueError("invalid_visual_rule_identity")
        return rule

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM camera_visual_sensor_rules ORDER BY id LIMIT ?",
                    (MAX_RULES + 1,),
                ).fetchall()
                if len(rows) > MAX_RULES:
                    raise ValueError("visual_rule_limit")
                for row in rows:
                    self._rule(row)
        except (sqlite3.Error, ValueError, TypeError):
            raise StartupError("camera_visual_sensor_storage_invalid") from None

    @staticmethod
    def capability():
        machine = platform.machine().lower()
        architecture = (
            "arm64"
            if machine in {"arm64", "aarch64"}
            else "amd64"
            if machine in {"amd64", "x86_64"}
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
    def _summary(rule):
        return VisualSensorSummary(
            schemaVersion=1,
            ruleId=rule.ruleId,
            ruleRevision=rule.ruleRevision,
            cameraId=rule.cameraId,
            pipelineId=rule.pipelineId,
            pipelineRevision=rule.pipelineRevision,
            modelId=rule.modelId,
            modelRevision=rule.modelRevision,
            label=rule.label,
            state="unknown",
            status="unavailable",
            reason="no_trusted_frame",
            confidenceBps=0,
            count=0,
            automationEligible=False,
            accessControlEligible=False,
        )

    def configure(self, actor, core_id, home_id, rule_id, value):
        body = ConfigureVisualSensorRule.model_validate(value)
        self._scope(core_id, home_id)
        if body.rule.ruleId != rule_id:
            raise ApiError("revision_conflict", 409)
        try:
            with self.db.transaction() as connection:
                self._actor(connection, actor)
                old = connection.execute(
                    "SELECT * FROM camera_visual_sensor_rules WHERE id=?", (rule_id,)
                ).fetchone()
                if old is not None:
                    self._rule(old)
                current = 0 if old is None else old["revision"]
                if (
                    body.expectedRevision != current
                    or body.rule.ruleRevision != current + 1
                ):
                    raise ApiError("revision_conflict", 409)
                if (
                    old is None
                    and connection.execute(
                        "SELECT COUNT(*) FROM camera_visual_sensor_rules"
                    ).fetchone()[0]
                    >= MAX_RULES
                ):
                    raise ApiError("visual_sensor_limit_reached", 429)
                values = [
                    rule_id,
                    body.rule.ruleRevision,
                    body.rule.model_dump_json(),
                    actor.id,
                    actor.family_id,
                    float(self.settings.clock()),
                ]
                row = dict(
                    zip(
                        (
                            "id",
                            "revision",
                            "rule_json",
                            "actor_id",
                            "family_id",
                            "updated_at",
                        ),
                        values,
                    )
                )
                tag = self._tag(row)
                connection.execute(
                    "INSERT INTO camera_visual_sensor_rules VALUES(?,?,?,?,?,?,?) "
                    "ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,"
                    "rule_json=excluded.rule_json,actor_id=excluded.actor_id,"
                    "family_id=excluded.family_id,updated_at=excluded.updated_at,"
                    "envelope_tag=excluded.envelope_tag",
                    (*values, tag),
                )
                return {"schemaVersion": 1, "rule": self._summary(body.rule)}
        except ApiError:
            raise
        except (sqlite3.Error, ValueError, TypeError):
            raise ApiError("visual_sensor_storage_unavailable", 503) from None

    def summary(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        try:
            with self.db.connection() as connection:
                connection.execute("BEGIN")
                self._actor(connection, actor)
                rows = connection.execute(
                    "SELECT * FROM camera_visual_sensor_rules ORDER BY id LIMIT ?",
                    (MAX_RULES + 1,),
                ).fetchall()
                if len(rows) > MAX_RULES:
                    raise ValueError("visual_rule_limit")
                return {
                    "schemaVersion": 1,
                    "scope": self.scope,
                    "capability": self.capability(),
                    "rules": [self._summary(self._rule(row)) for row in rows],
                }
        except ApiError:
            raise
        except (sqlite3.Error, ValueError, TypeError):
            raise ApiError("visual_sensor_storage_unavailable", 503) from None
