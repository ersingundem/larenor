import hashlib
import hmac
import json
import sqlite3
import uuid
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from .models import CreateTrial, EvaluateTrialEvent


MAX_TRIALS = 128
MAX_EVENTS = 4096
MAX_EVENTS_PER_TRIAL = 512
MAX_EVENT_FUTURE_MS = 30_000


def _json(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False
    )


class AutomationTrialService:
    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings = db, auth, settings
        self.scope = HomeScope.model_validate(context.model_dump())
        self._key = hmac.new(
            key,
            b"larenor-automation-trial-v1\0"
            + self.scope.coreId.encode("ascii")
            + b"\0"
            + self.scope.homeId.encode("ascii"),
            hashlib.sha256,
        ).digest()

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    def _tag(self, domain, values):
        return hmac.new(
            self._key, domain + b"\0" + _json(values).encode("ascii"), hashlib.sha256
        ).hexdigest()

    def _trial_tag(self, row):
        return self._tag(b"trial", [row[name] for name in (
            "id", "account_id", "family_id", "request_key", "timezone",
            "local_start_date", "starts_at_ms", "ends_at_ms", "rules_json",
            "created_at_ms",
        )])

    def _event_tag(self, row):
        return self._tag(b"event", [row[name] for name in (
            "id", "trial_id", "account_id", "family_id", "request_key",
            "source", "event_key", "occurred_at_ms", "result_json", "created_at_ms",
        )])

    @staticmethod
    def _verified(row, expected):
        if row is None:
            raise ApiError("not_found", 404)
        if not hmac.compare_digest(row["record_tag"], expected):
            raise StartupError("automation_trial_storage_invalid")
        return row

    def _validate(self, connection):
        trials = connection.execute(
            "SELECT * FROM automation_trials ORDER BY id LIMIT ?", (MAX_TRIALS + 1,)
        ).fetchall()
        events = connection.execute(
            "SELECT * FROM automation_trial_events ORDER BY id LIMIT ?", (MAX_EVENTS + 1,)
        ).fetchall()
        if len(trials) > MAX_TRIALS or len(events) > MAX_EVENTS:
            raise StartupError("automation_trial_storage_invalid")
        for row in trials:
            self._verified(row, self._trial_tag(row))
            CreateTrial.model_validate({
                "schemaVersion": 1,
                "requestKey": row["request_key"],
                "timezone": row["timezone"],
                "localStartDate": row["local_start_date"],
                "rules": json.loads(row["rules_json"]),
            })
        for row in events:
            self._verified(row, self._event_tag(row))
            if not isinstance(json.loads(row["result_json"]), dict):
                raise ValueError("invalid_trial_event")

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                self._validate(connection)
        except StartupError:
            raise
        except (sqlite3.Error, TypeError, ValueError, json.JSONDecodeError):
            raise StartupError("automation_trial_storage_invalid") from None

    def _actor(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT role,disabled,must_change_password FROM users WHERE id=?", (actor.id,)
        ).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("invalid_session", 401)
        if row["role"] != "admin":
            raise ApiError("forbidden", 403)

    @staticmethod
    def _period(timezone_name, local_start):
        try:
            zone = ZoneInfo(timezone_name)
            start_date = date.fromisoformat(local_start)
            start = datetime.combine(start_date, time.min, zone)
            end = datetime.combine(start_date + timedelta(days=7), time.min, zone)
            if start.astimezone(timezone.utc).astimezone(zone).date() != start_date:
                raise ValueError("invalid_local_start")
            return zone, round(start.timestamp() * 1000), round(end.timestamp() * 1000)
        except (ValueError, ZoneInfoNotFoundError):
            raise ApiError("automation_trial_timezone_invalid", 400) from None

    def _public_trial(self, row, events):
        rules = json.loads(row["rules_json"])
        results = [json.loads(event["result_json"]) for event in events]
        triggered = sum(
            decision["state"] == "triggered"
            for result in results
            for decision in result["decisions"]
        )
        suppressed = sum(
            decision["state"] == "suppressed"
            for result in results
            for decision in result["decisions"]
        )
        return {
            "schemaVersion": 1,
            "id": row["id"],
            "timezone": row["timezone"],
            "localStartDate": row["local_start_date"],
            "startsAtMs": row["starts_at_ms"],
            "endsAtMs": row["ends_at_ms"],
            "utcDurationSeconds": (row["ends_at_ms"] - row["starts_at_ms"]) // 1000,
            "simulationOnly": True,
            "adapterWriteCount": 0,
            "rules": rules,
            "eventCount": len(results),
            "triggeredCount": triggered,
            "suppressedCount": suppressed,
            "events": results,
        }

    def _stored(self, connection, actor, trial_id):
        row = connection.execute(
            "SELECT * FROM automation_trials WHERE id=? AND account_id=? AND family_id=?",
            (trial_id, actor.id, actor.family_id),
        ).fetchone()
        return self._verified(row, self._trial_tag(row) if row is not None else "")

    def _events(self, connection, trial_id):
        rows = connection.execute(
            "SELECT * FROM automation_trial_events WHERE trial_id=? "
            "ORDER BY occurred_at_ms,id LIMIT ?", (trial_id, MAX_EVENTS_PER_TRIAL + 1)
        ).fetchall()
        if len(rows) > MAX_EVENTS_PER_TRIAL:
            raise StartupError("automation_trial_storage_invalid")
        return [self._verified(row, self._event_tag(row)) for row in rows]

    def create(self, actor, core_id, home_id, body):
        self._scope(core_id, home_id)
        body = CreateTrial.model_validate(body)
        _, starts_at, ends_at = self._period(body.timezone, body.localStartDate)
        now_ms = round(float(self.settings.clock()) * 1000)
        rules_json = _json([rule.model_dump(mode="json") for rule in body.rules])
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            self._validate(connection)
            existing = connection.execute(
                "SELECT * FROM automation_trials WHERE account_id=? AND family_id=? "
                "AND request_key=?", (actor.id, actor.family_id, body.requestKey)
            ).fetchone()
            if existing is not None:
                existing = self._verified(existing, self._trial_tag(existing))
                if (existing["timezone"], existing["local_start_date"], existing["rules_json"]) != (
                    body.timezone, body.localStartDate, rules_json
                ):
                    raise ApiError("idempotency_conflict", 409)
                return {"trial": self._public_trial(existing, self._events(connection, existing["id"]))}
            if connection.execute("SELECT COUNT(*) FROM automation_trials").fetchone()[0] >= MAX_TRIALS:
                raise ApiError("automation_trial_limit_reached", 429)
            row = {
                "id": uuid.uuid4().hex, "account_id": actor.id,
                "family_id": actor.family_id, "request_key": body.requestKey,
                "timezone": body.timezone, "local_start_date": body.localStartDate,
                "starts_at_ms": starts_at, "ends_at_ms": ends_at,
                "rules_json": rules_json, "created_at_ms": now_ms,
            }
            connection.execute(
                "INSERT INTO automation_trials VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (*row.values(), self._trial_tag(row)),
            )
            stored = self._stored(connection, actor, row["id"])
            return {"trial": self._public_trial(stored, [])}

    @staticmethod
    def _decision(rule, *, state, reason):
        return {
            "ruleId": rule["ruleId"], "deviceId": rule["deviceId"],
            "action": rule["action"], "priority": rule["priority"],
            "state": state, "reason": reason,
        }

    def _evaluate(self, trial, body):
        zone = ZoneInfo(trial["timezone"])
        rules = [
            rule for rule in json.loads(trial["rules_json"])
            if rule["eventKey"] == body.eventKey
        ]
        local = datetime.fromtimestamp(body.occurredAtMs / 1000, timezone.utc).astimezone(zone)
        outside = not (trial["starts_at_ms"] <= body.occurredAtMs < trial["ends_at_ms"])
        decisions, active = [], []
        for rule in rules:
            minute = local.hour * 60 + local.minute
            if outside:
                decisions.append(self._decision(rule, state="suppressed", reason="outside_trial"))
            elif local.weekday() not in rule["weekdays"] or not (
                rule["startMinute"] <= minute < rule["endMinute"]
            ):
                decisions.append(self._decision(rule, state="suppressed", reason="schedule_inactive"))
            else:
                active.append(rule)
        for device_id in sorted({rule["deviceId"] for rule in active}):
            candidates = [rule for rule in active if rule["deviceId"] == device_id]
            top = max(rule["priority"] for rule in candidates)
            winners = [rule for rule in candidates if rule["priority"] == top]
            for rule in candidates:
                if len(winners) > 1 and rule["priority"] == top:
                    decisions.append(self._decision(rule, state="suppressed", reason="equal_priority"))
                elif rule["priority"] == top:
                    decisions.append(self._decision(rule, state="triggered", reason="winner"))
                else:
                    decisions.append(self._decision(rule, state="suppressed", reason="lower_priority"))
        decisions.sort(key=lambda item: item["ruleId"])
        return {
            "schemaVersion": 1,
            "source": body.source,
            "eventKey": body.eventKey,
            "occurredAtMs": body.occurredAtMs,
            "localDateTime": local.isoformat(timespec="seconds"),
            "utcOffsetSeconds": int(local.utcoffset().total_seconds()),
            "fold": local.fold,
            "decisions": decisions,
            "adapterWriteCount": 0,
        }

    def evaluate(self, actor, core_id, home_id, trial_id, body):
        self._scope(core_id, home_id)
        body = EvaluateTrialEvent.model_validate(body)
        now_ms = round(float(self.settings.clock()) * 1000)
        if body.occurredAtMs > now_ms + MAX_EVENT_FUTURE_MS:
            raise ApiError("automation_trial_event_future", 409)
        with self.db.transaction() as connection:
            self._actor(connection, actor)
            self._validate(connection)
            trial = self._stored(connection, actor, trial_id)
            existing = connection.execute(
                "SELECT * FROM automation_trial_events WHERE account_id=? AND family_id=? "
                "AND request_key=?", (actor.id, actor.family_id, body.requestKey)
            ).fetchone()
            result = self._evaluate(trial, body)
            if existing is not None:
                existing = self._verified(existing, self._event_tag(existing))
                if json.loads(existing["result_json"]) != result or existing["trial_id"] != trial_id:
                    raise ApiError("idempotency_conflict", 409)
                return {"trial": self._public_trial(trial, self._events(connection, trial_id))}
            if connection.execute("SELECT COUNT(*) FROM automation_trial_events").fetchone()[0] >= MAX_EVENTS:
                raise ApiError("automation_trial_event_limit_reached", 429)
            if len(self._events(connection, trial_id)) >= MAX_EVENTS_PER_TRIAL:
                raise ApiError("automation_trial_event_limit_reached", 429)
            row = {
                "id": uuid.uuid4().hex, "trial_id": trial_id,
                "account_id": actor.id, "family_id": actor.family_id,
                "request_key": body.requestKey, "source": body.source,
                "event_key": body.eventKey, "occurred_at_ms": body.occurredAtMs,
                "result_json": _json(result), "created_at_ms": now_ms,
            }
            connection.execute(
                "INSERT INTO automation_trial_events VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (*row.values(), self._event_tag(row)),
            )
            return {"trial": self._public_trial(trial, self._events(connection, trial_id))}

    def snapshot(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._actor(connection, actor)
            self._validate(connection)
            rows = connection.execute(
                "SELECT * FROM automation_trials WHERE account_id=? AND family_id=? "
                "ORDER BY created_at_ms DESC,id DESC LIMIT 16", (actor.id, actor.family_id)
            ).fetchall()
            return {
                "schemaVersion": 1,
                "scope": self.scope.model_dump(),
                "trials": [
                    self._public_trial(
                        self._verified(row, self._trial_tag(row)),
                        self._events(connection, row["id"]),
                    )
                    for row in rows
                ],
            }
