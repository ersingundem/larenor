"""Bounded robust-baseline anomaly classification with explicit unknowns."""

import hashlib
import hmac
import json
import math
import sqlite3
import statistics
import uuid

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from . import schema


MODEL_VERSION = "robust-mad-v1"
MAX_OBSERVATIONS = 4096
MAX_PER_SERIES = 256
MIN_BASELINE_SAMPLES = 12
MIN_BASELINE_SPAN_MS = 11 * 60 * 1000
MAX_SAMPLE_AGE_MS = 5 * 60 * 1000
MAX_FUTURE_SKEW_MS = 30 * 1000


def _canonical(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False
    ).encode("ascii")


class HabitAnomalyService:
    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings = db, auth, settings
        self.scope = HomeScope.model_validate(context.model_dump())
        self._key = hmac.new(
            key,
            b"larenor-habit-anomaly-v1\0" + self.scope.coreId.encode("ascii")
            + b"\0" + self.scope.homeId.encode("ascii"),
            hashlib.sha256,
        ).digest()

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    def _tag(self, domain, values):
        return hmac.new(self._key, domain + b"\0" + _canonical(values), hashlib.sha256).hexdigest()

    def _observation_tag(self, row):
        return self._tag(b"observation", [row[name] for name in (
            "id", "account_id", "family_id", "request_key", "series_id", "metric",
            "unit", "value", "observed_at_ms", "created_at_ms",
        )])

    def _feedback_tag(self, row):
        return self._tag(b"feedback", [row[name] for name in (
            "id", "observation_id", "account_id", "family_id", "request_key",
            "label", "created_at_ms",
        )])

    @staticmethod
    def _verified(row, expected):
        if row is None:
            raise ApiError("not_found", 404)
        if not hmac.compare_digest(row["record_tag"], expected):
            raise StartupError("habit_anomaly_storage_invalid")
        return row

    def _validate(self, connection):
        observations = connection.execute(
            "SELECT * FROM habit_anomaly_observations ORDER BY id LIMIT ?",
            (MAX_OBSERVATIONS + 1,),
        ).fetchall()
        if len(observations) > MAX_OBSERVATIONS:
            raise StartupError("habit_anomaly_storage_invalid")
        for row in observations:
            self._verified(row, self._observation_tag(row))
            if not math.isfinite(row["value"]):
                raise StartupError("habit_anomaly_storage_invalid")
        feedback = connection.execute(
            "SELECT * FROM habit_anomaly_feedback ORDER BY id LIMIT ?",
            (MAX_OBSERVATIONS + 1,),
        ).fetchall()
        if len(feedback) > MAX_OBSERVATIONS:
            raise StartupError("habit_anomaly_storage_invalid")
        for row in feedback:
            self._verified(row, self._feedback_tag(row))

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                self._validate(connection)
        except StartupError:
            raise
        except (sqlite3.Error, TypeError, ValueError):
            raise StartupError("habit_anomaly_storage_invalid") from None

    def _actor(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT disabled,must_change_password FROM users WHERE id=?", (actor.id,)
        ).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("invalid_session", 401)

    def _rows(self, connection, actor, series_id):
        rows = connection.execute(
            "SELECT * FROM habit_anomaly_observations WHERE account_id=? AND "
            "family_id=? AND series_id=? ORDER BY observed_at_ms,id LIMIT ?",
            (actor.id, actor.family_id, series_id, MAX_PER_SERIES),
        ).fetchall()
        return [self._verified(row, self._observation_tag(row)) for row in rows]

    def _feedback(self, connection, actor, observation_id):
        row = connection.execute(
            "SELECT * FROM habit_anomaly_feedback WHERE account_id=? AND family_id=? "
            "AND observation_id=?", (actor.id, actor.family_id, observation_id)
        ).fetchone()
        return None if row is None else self._verified(row, self._feedback_tag(row))["label"]

    def _report(self, connection, actor, rows, now_ms):
        current = rows[-1]
        baseline = rows[:-1]
        reason = None
        classification = "unknown"
        center = tolerance = None
        if now_ms - current["observed_at_ms"] > MAX_SAMPLE_AGE_MS:
            reason = "stale_data"
        elif len(baseline) < MIN_BASELINE_SAMPLES:
            reason = "insufficient_samples"
        elif baseline[-1]["observed_at_ms"] - baseline[0]["observed_at_ms"] < MIN_BASELINE_SPAN_MS:
            reason = "insufficient_span"
        else:
            values = [row["value"] for row in baseline]
            center = statistics.median(values)
            mad = statistics.median(abs(value - center) for value in values)
            tolerance = max(3 * 1.4826 * mad, abs(center) * 0.1, 0.001)
            classification = (
                "anomaly" if abs(current["value"] - center) > tolerance else "normal"
            )
        return {
            "schemaVersion": 1,
            "seriesId": current["series_id"],
            "metric": current["metric"],
            "unit": current["unit"],
            "modelVersion": MODEL_VERSION,
            "classification": classification,
            "unknownReason": reason,
            "sampleCount": len(rows),
            "minimumBaselineSamples": MIN_BASELINE_SAMPLES,
            "current": {
                "observationId": current["id"],
                "value": current["value"],
                "observedAtMs": current["observed_at_ms"],
                "feedback": self._feedback(connection, actor, current["id"]),
            },
            "baseline": None if center is None else {
                "sampleCount": len(baseline),
                "center": center,
                "tolerance": tolerance,
            },
            "missingDataIsUnknown": True,
        }

    def record(self, actor, core_id, home_id, body):
        self._scope(core_id, home_id)
        now_ms = round(float(self.settings.clock()) * 1000)
        if (
            body.observedAtMs > now_ms + MAX_FUTURE_SKEW_MS
            or now_ms - body.observedAtMs > MAX_SAMPLE_AGE_MS
        ):
            raise ApiError("habit_observation_stale", 409)
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            self._validate(connection)
            existing = connection.execute(
                "SELECT * FROM habit_anomaly_observations WHERE account_id=? AND "
                "family_id=? AND request_key=?",
                (actor.id, actor.family_id, body.requestKey),
            ).fetchone()
            expected = [body.seriesId, body.metric, body.unit, body.value, body.observedAtMs]
            if existing is not None:
                existing = self._verified(existing, self._observation_tag(existing))
                actual = [existing[name] for name in (
                    "series_id", "metric", "unit", "value", "observed_at_ms"
                )]
                if actual != expected:
                    raise ApiError("idempotency_conflict", 409)
                return {"report": self._report(
                    connection, actor, self._rows(connection, actor, body.seriesId), now_ms
                )}
            series = self._rows(connection, actor, body.seriesId)
            if series and (series[-1]["metric"], series[-1]["unit"]) != (body.metric, body.unit):
                raise ApiError("habit_series_changed", 409)
            if connection.execute(
                "SELECT COUNT(*) FROM habit_anomaly_observations"
            ).fetchone()[0] >= MAX_OBSERVATIONS:
                raise ApiError("habit_anomaly_limit_reached", 429)
            row = {
                "id": uuid.uuid4().hex, "account_id": actor.id,
                "family_id": actor.family_id, "request_key": body.requestKey,
                "series_id": body.seriesId, "metric": body.metric,
                "unit": body.unit, "value": body.value,
                "observed_at_ms": body.observedAtMs, "created_at_ms": now_ms,
            }
            connection.execute(
                "INSERT INTO habit_anomaly_observations VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (*row.values(), self._observation_tag(row)),
            )
            connection.execute(
                "DELETE FROM habit_anomaly_observations WHERE id IN (SELECT id FROM "
                "habit_anomaly_observations WHERE account_id=? AND family_id=? AND "
                "series_id=? ORDER BY observed_at_ms DESC,id DESC LIMIT -1 OFFSET ?)",
                (actor.id, actor.family_id, body.seriesId, MAX_PER_SERIES),
            )
            return {"report": self._report(
                connection, actor, self._rows(connection, actor, body.seriesId), now_ms
            )}

    def mark(self, actor, core_id, home_id, observation_id, body):
        self._scope(core_id, home_id)
        if observation_id != body.expectedObservationId:
            raise ApiError("habit_observation_changed", 409)
        now_ms = round(float(self.settings.clock()) * 1000)
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            self._validate(connection)
            observation = connection.execute(
                "SELECT * FROM habit_anomaly_observations WHERE id=? AND account_id=? "
                "AND family_id=?", (observation_id, actor.id, actor.family_id)
            ).fetchone()
            observation = self._verified(
                observation,
                self._observation_tag(observation) if observation is not None else "",
            )
            existing = connection.execute(
                "SELECT * FROM habit_anomaly_feedback WHERE account_id=? AND family_id=? "
                "AND request_key=?", (actor.id, actor.family_id, body.requestKey)
            ).fetchone()
            if existing is not None:
                existing = self._verified(existing, self._feedback_tag(existing))
                if (existing["observation_id"], existing["label"]) != (
                    observation_id, body.label
                ):
                    raise ApiError("idempotency_conflict", 409)
            else:
                prior = connection.execute(
                    "SELECT 1 FROM habit_anomaly_feedback WHERE account_id=? AND "
                    "family_id=? AND observation_id=?",
                    (actor.id, actor.family_id, observation_id),
                ).fetchone()
                if prior is not None:
                    raise ApiError("habit_feedback_changed", 409)
                row = {
                    "id": uuid.uuid4().hex, "observation_id": observation_id,
                    "account_id": actor.id, "family_id": actor.family_id,
                    "request_key": body.requestKey, "label": body.label,
                    "created_at_ms": now_ms,
                }
                connection.execute(
                    "INSERT INTO habit_anomaly_feedback VALUES(?,?,?,?,?,?,?,?)",
                    (*row.values(), self._feedback_tag(row)),
                )
            return {"report": self._report(
                connection, actor,
                self._rows(connection, actor, observation["series_id"]), now_ms,
            )}

    def snapshot(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        now_ms = round(float(self.settings.clock()) * 1000)
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._actor(connection, actor)
            self._validate(connection)
            series_ids = [row[0] for row in connection.execute(
                "SELECT DISTINCT series_id FROM habit_anomaly_observations WHERE "
                "account_id=? AND family_id=? ORDER BY series_id LIMIT 64",
                (actor.id, actor.family_id),
            )]
            reports = [self._report(
                connection, actor, self._rows(connection, actor, series_id), now_ms
            ) for series_id in series_ids]
        return {"schemaVersion": 1, "scope": self.scope.model_dump(), "reports": reports}
