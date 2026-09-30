import hashlib
import hmac
import json
import threading
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..errors import ApiError, StartupError
from .models import (
    ConfigurePowerRecoveryRequest,
    PowerEffectReceipt,
    PowerEffectRequest,
    PowerRecoveryPolicy,
    PowerRecoveryPolicyResponse,
    PowerRecoveryRun,
    PowerRecoveryStatus,
    PowerStepReceipt,
    RetryPowerRecoveryRequest,
    UpsEventReceipt,
    UpsPowerEvent,
)


_ACTIVE_WORK = (
    ("bounded_transfer_receipts", "state='accepted'"),
    ("plugin_jobs", "state IN ('queued','running')"),
    ("media_inspections", "state IN ('queued','running')"),
    ("media_installations", "state IN ('queued','running','container_started')"),
    ("media_service_bootstraps", "state IN ('queued','running','credentials_configured','wiring_partial')"),
    ("media_qbittorrent_configurations", "state IN ('queued','running')"),
    ("media_arr_configurations", "state IN ('queued','running')"),
    ("media_seerr_bootstraps", "state IN ('queued','running')"),
    ("media_music_assistant_bootstraps", "state IN ('queued','running')"),
    ("component_update_jobs", "state IN ('queued','validating','ready','running')"),
)
_HEAVY_MUTATION_PREFIXES = (
    "/api/v1/admin/plugins/jobs",
    "/api/v1/admin/media/",
    "/api/v1/admin/backups/export",
    "/api/v1/admin/backups/drills",
    "/api/v1/admin/backups/immutable-target",
    "/api/v1/admin/component-updates",
    "/api/v1/admin/proxmox-power/",
    "/api/v1/admin/keenetic-commands/",
)
_EVENT_SKEW_SECONDS = 300
_DRAIN_SECONDS = 30


class UnavailablePowerRecoveryExecutor:
    available = False

    def execute(self, _request):
        raise RuntimeError("power_recovery_executor_unavailable")

    def reconcile(self, _request):
        """No observation is safer than replaying an unproved host effect."""
        return None


class PowerRecoveryService:
    """Durable, idempotent UPS event state machine with ordered effects."""

    def __init__(self, db, auth, settings, key, executor=None):
        self.db, self.auth, self.settings = db, auth, settings
        self._key = key
        self._executor = executor or UnavailablePowerRecoveryExecutor()
        self._lock = threading.RLock()
        self.validate_storage()
        self._recover_incomplete()

    @staticmethod
    def _aad(revision):
        return f"larenor-power-recovery-token-v1:{revision}".encode("ascii")

    def _assert_admin(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT role,revision,disabled,must_change_password FROM users WHERE id=?",
            (actor.id,),
        ).fetchone()
        if (
            row is None
            or row["role"] != "admin"
            or row["disabled"]
            or row["must_change_password"]
        ):
            raise ApiError("forbidden", 403)
        return row["revision"]

    @staticmethod
    def _policy(row):
        if row is None:
            return None
        try:
            targets = json.loads(row["targets_json"])
            return PowerRecoveryPolicy(
                contractVersion=1,
                revision=row["revision"],
                sourceId=row["source_id"],
                criticalRuntimeSeconds=row["critical_runtime_seconds"],
                restoreStableSeconds=row["restore_stable_seconds"],
                targets=targets,
                configuredAt=row["configured_at"],
            )
        except (TypeError, ValueError, json.JSONDecodeError, ValidationError):
            raise StartupError("power_recovery_storage_invalid") from None

    def _policy_row(self, connection):
        return connection.execute(
            "SELECT * FROM power_recovery_policy WHERE id=1"
        ).fetchone()

    def configure(self, actor, raw):
        body = ConfigurePowerRecoveryRequest.model_validate(raw)
        now = int(self.settings.clock())
        with self._lock, self.db.transaction() as connection:
            self._assert_admin(connection, actor)
            current = self._policy_row(connection)
            revision = 1 if current is None else current["revision"] + 1
            if body.expectedRevision != revision - 1:
                raise ApiError("revision_conflict", 409)
            active = connection.execute(
                "SELECT active_run_id FROM power_recovery_state WHERE id=1"
            ).fetchone()
            if active is None or active["active_run_id"] is not None:
                raise ApiError("power_recovery_active", 409)
            nonce = uuid.uuid4().bytes[:12]
            ciphertext = AESGCM(self._key).encrypt(
                nonce, body.sourceToken.encode("utf-8"), self._aad(revision)
            )
            targets = json.dumps(
                [target.model_dump() for target in body.targets],
                separators=(",", ":"),
                sort_keys=True,
            )
            connection.execute(
                """INSERT INTO power_recovery_policy(
                    id,revision,source_id,critical_runtime_seconds,
                    restore_stable_seconds,targets_json,token_nonce,
                    token_ciphertext,configured_at) VALUES(1,?,?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,
                    source_id=excluded.source_id,
                    critical_runtime_seconds=excluded.critical_runtime_seconds,
                    restore_stable_seconds=excluded.restore_stable_seconds,
                    targets_json=excluded.targets_json,token_nonce=excluded.token_nonce,
                    token_ciphertext=excluded.token_ciphertext,
                    configured_at=excluded.configured_at""",
                (
                    revision,
                    body.sourceId,
                    body.criticalRuntimeSeconds,
                    body.restoreStableSeconds,
                    targets,
                    nonce,
                    ciphertext,
                    now,
                ),
            )
            connection.execute(
                """UPDATE power_recovery_state SET source_state='online',
                    gate_state='open',last_sequence=0,last_observed_at=NULL,
                    online_since=NULL WHERE id=1"""
            )
            return PowerRecoveryPolicyResponse(policy=self._policy(self._policy_row(connection)))

    def policy(self, actor):
        with self.db.connection() as connection:
            self._assert_admin(connection, actor)
            return PowerRecoveryPolicyResponse(policy=self._policy(self._policy_row(connection)))

    def _token(self, row):
        try:
            return AESGCM(self._key).decrypt(
                row["token_nonce"], row["token_ciphertext"], self._aad(row["revision"])
            ).decode("utf-8")
        except (InvalidTag, UnicodeError, ValueError):
            raise StartupError("power_recovery_storage_invalid") from None

    @staticmethod
    def _same_event(row, body):
        return (
            row["source_revision"], row["sequence"], row["state"],
            row["charge_percent"], row["runtime_seconds"], row["observed_at"],
        ) == (
            body.sourceRevision, body.sequence, body.state,
            body.chargePercent, body.runtimeSeconds, body.observedAt,
        )

    def ingest(self, token, raw):
        try:
            body = UpsPowerEvent.model_validate(raw)
        except ValidationError:
            raise ApiError("invalid_request") from None
        now = int(self.settings.clock())
        if not isinstance(token, str) or not token:
            raise ApiError("invalid_ups_token", 401)
        with self._lock, self.db.transaction() as connection:
            row = self._policy_row(connection)
            policy = self._policy(row)
            if policy is None:
                raise ApiError("power_recovery_unconfigured", 503)
            expected = self._token(row)
            if not hmac.compare_digest(
                hashlib.sha256(token.encode("utf-8")).digest(),
                hashlib.sha256(expected.encode("utf-8")).digest(),
            ):
                raise ApiError("invalid_ups_token", 401)
            if body.sourceId != policy.sourceId or body.sourceRevision != policy.revision:
                raise ApiError("power_event_stale", 409)
            duplicate = connection.execute(
                "SELECT * FROM power_recovery_events WHERE event_id=?",
                (body.eventId,),
            ).fetchone()
            if duplicate is not None:
                if not self._same_event(duplicate, body):
                    raise ApiError("idempotency_conflict", 409)
                return UpsEventReceipt(
                    accepted=True, duplicate=True, status=self._status(connection)
                )
            state = connection.execute(
                "SELECT * FROM power_recovery_state WHERE id=1"
            ).fetchone()
            if (
                body.sequence != state["last_sequence"] + 1
                or abs(now - body.observedAt) > _EVENT_SKEW_SECONDS
                or state["last_observed_at"] is not None
                and body.observedAt < state["last_observed_at"]
            ):
                raise ApiError("power_event_stale", 409)
            connection.execute(
                "INSERT INTO power_recovery_events VALUES(?,?,?,?,?,?,?,?)",
                (
                    body.eventId, body.sourceRevision, body.sequence, body.state,
                    body.chargePercent, body.runtimeSeconds, body.observedAt, now,
                ),
            )
            online_since = body.observedAt if body.state == "online" else None
            connection.execute(
                """UPDATE power_recovery_state SET source_state=?,last_sequence=?,
                    last_observed_at=?,online_since=? WHERE id=1""",
                (body.state, body.sequence, body.observedAt, online_since),
            )
            if (
                state["active_run_id"] is None
                and (
                    body.state == "lowBattery"
                    or body.state == "onBattery"
                    and body.runtimeSeconds <= policy.criticalRuntimeSeconds
                )
            ):
                self._create_run(connection, policy, body, now)
            elif state["active_run_id"] is not None:
                if body.state == "online":
                    connection.execute(
                        "UPDATE power_recovery_runs SET restore_eligible_at=?,updated_at=? WHERE run_id=?",
                        (body.observedAt + policy.restoreStableSeconds, now, state["active_run_id"]),
                    )
                    self._prepare_restore_after_failed_shutdown(
                        connection, state["active_run_id"], now
                    )
                else:
                    connection.execute(
                        "UPDATE power_recovery_runs SET restore_eligible_at=NULL,updated_at=? WHERE run_id=?",
                        (now, state["active_run_id"]),
                    )
            self._trim(connection)
            return UpsEventReceipt(
                accepted=True, duplicate=False, status=self._status(connection)
            )

    def _create_run(self, connection, policy, event, now):
        run_id = uuid.uuid4().hex
        connection.execute(
            "INSERT INTO power_recovery_runs VALUES(?,?,?,?,?,?,NULL,NULL)",
            (run_id, policy.revision, event.eventId, "draining", now, now),
        )
        steps = [("holdNewWork", None), ("drainActiveWork", None), ("checkpointDatabase", None)]
        steps.extend(("shutdownTarget", target) for target in policy.targets)
        steps.extend(
            ("startTarget", target)
            for target in reversed(policy.targets)
            if target.startOnRestore
        )
        steps.append(("releaseNewWork", None))
        for sequence, (action, target) in enumerate(steps, 1):
            connection.execute(
                "INSERT INTO power_recovery_steps VALUES(?,?,?,?,?,?,?,?,?,?)",
                (
                    uuid.uuid4().hex, run_id, sequence, action,
                    None if target is None else target.targetId,
                    None if target is None else target.kind,
                    "queued", "pending", now, now,
                ),
            )
        connection.execute(
            "UPDATE power_recovery_state SET gate_state='held',active_run_id=? WHERE id=1",
            (run_id,),
        )

    def _trim(self, connection):
        old_runs = connection.execute(
            "SELECT run_id FROM power_recovery_runs WHERE state IN ('completed','failed') ORDER BY created_at DESC LIMIT -1 OFFSET 32"
        ).fetchall()
        for row in old_runs:
            connection.execute("DELETE FROM power_recovery_steps WHERE run_id=?", (row["run_id"],))
            connection.execute("DELETE FROM power_recovery_runs WHERE run_id=?", (row["run_id"],))
        connection.execute(
            """DELETE FROM power_recovery_events WHERE event_id IN (
                SELECT event_id FROM power_recovery_events
                WHERE event_id NOT IN (SELECT trigger_event_id FROM power_recovery_runs)
                ORDER BY received_at DESC LIMIT -1 OFFSET 256
            )"""
        )

    @staticmethod
    def _prepare_restore_after_failed_shutdown(connection, run_id, now):
        run = connection.execute(
            "SELECT state FROM power_recovery_runs WHERE run_id=?", (run_id,)
        ).fetchone()
        if run is None or run["state"] != "failed":
            return
        failed = connection.execute(
            "SELECT action FROM power_recovery_steps WHERE run_id=? AND state='failed' ORDER BY sequence LIMIT 1",
            (run_id,),
        ).fetchone()
        if failed is None or failed["action"] in {"startTarget", "releaseNewWork"}:
            return
        succeeded = {
            row["target_id"]
            for row in connection.execute(
                "SELECT target_id FROM power_recovery_steps WHERE run_id=? AND action='shutdownTarget' AND state='succeeded'",
                (run_id,),
            )
        }
        connection.execute(
            """UPDATE power_recovery_steps SET state='skipped',updated_at=?
                WHERE run_id=? AND action IN ('holdNewWork','drainActiveWork',
                'checkpointDatabase','shutdownTarget') AND state IN ('queued','failed')""",
            (now, run_id),
        )
        for step in connection.execute(
            "SELECT step_id,target_id FROM power_recovery_steps WHERE run_id=? AND action='startTarget'",
            (run_id,),
        ):
            if step["target_id"] not in succeeded:
                connection.execute(
                    "UPDATE power_recovery_steps SET state='skipped',result_code='restore_disabled',updated_at=? WHERE step_id=?",
                    (now, step["step_id"]),
                )
        connection.execute(
            "UPDATE power_recovery_runs SET state='restoring',failure_code=NULL,updated_at=? WHERE run_id=?",
            (now, run_id),
        )

    @staticmethod
    def _step(row):
        return PowerStepReceipt(
            stepId=row["step_id"], sequence=row["sequence"], action=row["action"],
            targetId=row["target_id"], targetKind=row["target_kind"], state=row["state"],
            resultCode=row["result_code"], createdAt=row["created_at"], updatedAt=row["updated_at"],
        )

    def _run(self, connection, row):
        steps = connection.execute(
            "SELECT * FROM power_recovery_steps WHERE run_id=? ORDER BY sequence",
            (row["run_id"],),
        ).fetchall()
        state = connection.execute(
            "SELECT gate_state FROM power_recovery_state WHERE id=1"
        ).fetchone()
        return PowerRecoveryRun(
            runId=row["run_id"], policyRevision=row["policy_revision"],
            triggerEventId=row["trigger_event_id"], state=row["state"],
            gateState=state["gate_state"], createdAt=row["created_at"],
            updatedAt=row["updated_at"], restoreEligibleAt=row["restore_eligible_at"],
            failureCode=row["failure_code"], steps=[self._step(item) for item in steps],
        )

    def _status(self, connection):
        state = connection.execute("SELECT * FROM power_recovery_state WHERE id=1").fetchone()
        policy = self._policy(self._policy_row(connection))
        rows = connection.execute(
            "SELECT * FROM power_recovery_runs ORDER BY created_at DESC LIMIT 20"
        ).fetchall()
        runs = [self._run(connection, row) for row in rows]
        active = next((run for run in runs if run.runId == state["active_run_id"]), None)
        return PowerRecoveryStatus(
            policy=policy,
            sourceState="unconfigured" if policy is None else state["source_state"],
            gateState=state["gate_state"], lastSequence=state["last_sequence"],
            lastObservedAt=state["last_observed_at"], activeRun=active, recentRuns=runs,
        )

    def status(self, actor):
        with self.db.connection() as connection:
            self._assert_admin(connection, actor)
            return self._status(connection)

    def allows_request(self, method, path):
        if method not in {"POST", "PUT", "PATCH", "DELETE"}:
            return True
        if path.startswith("/api/v1/admin/power-recovery"):
            return True
        with self.db.connection() as connection:
            held = connection.execute(
                "SELECT gate_state FROM power_recovery_state WHERE id=1"
            ).fetchone()["gate_state"] == "held"
        return not held or not any(path.startswith(prefix) for prefix in _HEAVY_MUTATION_PREFIXES)

    def gate_held(self):
        with self.db.connection() as connection:
            return connection.execute(
                "SELECT gate_state FROM power_recovery_state WHERE id=1"
            ).fetchone()["gate_state"] == "held"

    def _recover_incomplete(self):
        now = int(self.settings.clock())
        effects = []
        with self.db.transaction() as connection:
            state = connection.execute(
                "SELECT active_run_id FROM power_recovery_state WHERE id=1"
            ).fetchone()
            if state["active_run_id"] is not None:
                run = connection.execute(
                    "SELECT * FROM power_recovery_runs WHERE run_id=?",
                    (state["active_run_id"],),
                ).fetchone()
                policy = self._policy(self._policy_row(connection))
                targets = (
                    {}
                    if policy is None or run is None
                    or policy.revision != run["policy_revision"]
                    else {target.targetId: target for target in policy.targets}
                )
                connection.execute(
                    """UPDATE power_recovery_steps SET state='queued',
                        result_code='pending',updated_at=?
                        WHERE run_id=? AND state='executing'
                        AND action='checkpointDatabase'""",
                    (now, state["active_run_id"]),
                )
                for step in connection.execute(
                    """SELECT * FROM power_recovery_steps
                        WHERE run_id=? AND state='executing'
                        AND action IN ('shutdownTarget','startTarget')
                        ORDER BY sequence""",
                    (state["active_run_id"],),
                ).fetchall():
                    target = targets.get(step["target_id"])
                    if target is None or target.kind != step["target_kind"]:
                        effects.append((step["step_id"], step["updated_at"], None))
                        continue
                    effects.append((
                        step["step_id"],
                        step["updated_at"],
                        PowerEffectRequest(
                            contractVersion=1,
                            runId=step["run_id"],
                            stepId=step["step_id"],
                            action=(
                                "shutdown"
                                if step["action"] == "shutdownTarget"
                                else "start"
                            ),
                            target=target,
                            deadlineAt=step["updated_at"] + target.timeoutSeconds,
                        ),
                    ))
        reconciler = getattr(self._executor, "reconcile", None)
        for step_id, started_at, effect in effects:
            receipt = None
            if effect is not None and callable(reconciler):
                try:
                    receipt = self._validated_effect_receipt(
                        effect, reconciler(effect), not_before=started_at
                    )
                except Exception:
                    receipt = None
            finished_at = now if receipt is None else receipt.completedAt
            with self.db.transaction() as connection:
                current = connection.execute(
                    "SELECT state,run_id FROM power_recovery_steps WHERE step_id=?",
                    (step_id,),
                ).fetchone()
                if current is None or current["state"] != "executing":
                    continue
                if receipt is not None:
                    self._finish_step(
                        connection, step_id, "succeeded", "completed", finished_at
                    )
                    continue
                self._finish_step(
                    connection,
                    step_id,
                    "uncertain",
                    "reconciliation_required",
                    finished_at,
                )
                connection.execute(
                    """UPDATE power_recovery_runs
                        SET state='failed',failure_code='effect_failed',updated_at=?
                        WHERE run_id=?""",
                    (finished_at, current["run_id"]),
                )

    def retry(self, actor, run_id, raw):
        body = RetryPowerRecoveryRequest.model_validate(raw)
        now = int(self.settings.clock())
        with self._lock, self.db.transaction() as connection:
            self._assert_admin(connection, actor)
            state = connection.execute(
                "SELECT * FROM power_recovery_state WHERE id=1"
            ).fetchone()
            run = connection.execute(
                "SELECT * FROM power_recovery_runs WHERE run_id=?", (run_id,)
            ).fetchone()
            failed = connection.execute(
                "SELECT * FROM power_recovery_steps WHERE run_id=? AND state='failed' ORDER BY sequence LIMIT 1",
                (run_id,),
            ).fetchone()
            if (
                run is None
                or state["active_run_id"] != run_id
                or run["state"] != "failed"
                or failed is None
                or run["updated_at"] != body.expectedUpdatedAt
            ):
                raise ApiError("revision_conflict", 409)
            restoring = failed["action"] in {"startTarget", "releaseNewWork"}
            if restoring:
                if (
                    state["source_state"] != "online"
                    or run["restore_eligible_at"] is None
                    or now < run["restore_eligible_at"]
                ):
                    raise ApiError("power_restore_not_stable", 409)
            elif state["source_state"] == "online":
                raise ApiError("power_shutdown_no_longer_required", 409)
            connection.execute(
                "UPDATE power_recovery_steps SET state='queued',result_code='pending',updated_at=? WHERE step_id=?",
                (now, failed["step_id"]),
            )
            connection.execute(
                "UPDATE power_recovery_runs SET state=?,failure_code=NULL,updated_at=? WHERE run_id=?",
                ("restoring" if restoring else "draining", now, run_id),
            )
            return self._run(
                connection,
                connection.execute(
                    "SELECT * FROM power_recovery_runs WHERE run_id=?", (run_id,)
                ).fetchone(),
            )

    def validate_storage(self):
        with self.db.connection() as connection:
            state = connection.execute("SELECT * FROM power_recovery_state WHERE id=1").fetchone()
            if state is None:
                raise StartupError("power_recovery_storage_invalid")
            policy = self._policy(self._policy_row(connection))
            if policy is not None:
                self._token(self._policy_row(connection))
            active = state["active_run_id"]
            if active is not None and connection.execute(
                "SELECT 1 FROM power_recovery_runs WHERE run_id=? AND state != 'completed'",
                (active,),
            ).fetchone() is None:
                raise StartupError("power_recovery_storage_invalid")

    def _active_work(self, connection):
        now = int(self.settings.clock())
        for table, where in _ACTIVE_WORK:
            sql = f"SELECT 1 FROM {table} WHERE {where} LIMIT 1"
            if connection.execute(sql, {"now": now}).fetchone() is not None:
                return True
        return False

    @staticmethod
    def _finish_step(connection, step_id, state, code, now):
        connection.execute(
            "UPDATE power_recovery_steps SET state=?,result_code=?,updated_at=? WHERE step_id=?",
            (state, code, now, step_id),
        )

    def _validated_effect_receipt(self, effect, raw, *, not_before):
        receipt = PowerEffectReceipt.model_validate(raw)
        if (
            receipt.runId != effect.runId
            or receipt.stepId != effect.stepId
            or receipt.targetId != effect.target.targetId
            or receipt.action != effect.action
            or receipt.completedAt < not_before
            or receipt.completedAt > effect.deadlineAt
            or receipt.completedAt > int(self.settings.clock()) + 5
        ):
            raise ValueError("power_effect_receipt_mismatch")
        return receipt

    def tick(self):
        with self._lock:
            return self._tick_locked()

    def _tick_locked(self):
        now = int(self.settings.clock())
        effect = None
        with self.db.transaction() as connection:
            state = connection.execute("SELECT * FROM power_recovery_state WHERE id=1").fetchone()
            if state["active_run_id"] is None:
                return False
            run = connection.execute(
                "SELECT * FROM power_recovery_runs WHERE run_id=?", (state["active_run_id"],)
            ).fetchone()
            if run["state"] in {"completed", "failed"}:
                return False
            step = connection.execute(
                "SELECT * FROM power_recovery_steps WHERE run_id=? AND state='queued' ORDER BY sequence LIMIT 1",
                (run["run_id"],),
            ).fetchone()
            if step is None:
                return False
            if step["action"] in {"startTarget", "releaseNewWork"}:
                if (
                    state["source_state"] != "online"
                    or run["restore_eligible_at"] is None
                    or now < run["restore_eligible_at"]
                ):
                    if run["state"] != "protected":
                        connection.execute(
                            "UPDATE power_recovery_runs SET state='protected',updated_at=? WHERE run_id=?",
                            (now, run["run_id"]),
                        )
                    return False
                connection.execute(
                    "UPDATE power_recovery_runs SET state='restoring',updated_at=? WHERE run_id=?",
                    (now, run["run_id"]),
                )
            action = step["action"]
            if action == "holdNewWork":
                self._finish_step(connection, step["step_id"], "succeeded", "completed", now)
            elif action == "drainActiveWork":
                if not self._active_work(connection):
                    self._finish_step(connection, step["step_id"], "succeeded", "no_active_work", now)
                elif now - run["created_at"] >= _DRAIN_SECONDS:
                    self._finish_step(connection, step["step_id"], "failed", "active_work_timeout", now)
                    connection.execute(
                        "UPDATE power_recovery_runs SET state='failed',failure_code='active_work_timeout',updated_at=? WHERE run_id=?",
                        (now, run["run_id"]),
                    )
                else:
                    return False
            elif action == "checkpointDatabase":
                connection.execute(
                    "UPDATE power_recovery_steps SET state='executing',updated_at=? WHERE step_id=?",
                    (now, step["step_id"]),
                )
            elif action in {"shutdownTarget", "startTarget"}:
                policy = self._policy(self._policy_row(connection))
                target = next(item for item in policy.targets if item.targetId == step["target_id"])
                connection.execute(
                    "UPDATE power_recovery_steps SET state='executing',updated_at=? WHERE step_id=?",
                    (now, step["step_id"]),
                )
                connection.execute(
                    "UPDATE power_recovery_runs SET state=?,updated_at=? WHERE run_id=?",
                    ("shuttingDown" if action == "shutdownTarget" else "restoring", now, run["run_id"]),
                )
                effect = PowerEffectRequest(
                    contractVersion=1, runId=run["run_id"], stepId=step["step_id"],
                    action="shutdown" if action == "shutdownTarget" else "start",
                    target=target, deadlineAt=now + target.timeoutSeconds,
                )
            elif action == "releaseNewWork":
                self._finish_step(connection, step["step_id"], "succeeded", "completed", now)
                connection.execute(
                    "UPDATE power_recovery_runs SET state='completed',updated_at=? WHERE run_id=?",
                    (now, run["run_id"]),
                )
                connection.execute(
                    "UPDATE power_recovery_state SET gate_state='open',active_run_id=NULL WHERE id=1"
                )
            if action == "checkpointDatabase":
                checkpoint_step = step["step_id"]
            else:
                checkpoint_step = None
        if checkpoint_step is not None:
            ok = False
            try:
                with self.db.connection() as connection:
                    ok = connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0] == 0
            except Exception:
                ok = False
            with self.db.transaction() as connection:
                self._finish_step(
                    connection, checkpoint_step, "succeeded" if ok else "failed",
                    "completed" if ok else "checkpoint_failed", int(self.settings.clock()),
                )
                if not ok:
                    connection.execute(
                        "UPDATE power_recovery_runs SET state='failed',failure_code='checkpoint_failed',updated_at=? WHERE run_id=?",
                        (int(self.settings.clock()), state["active_run_id"]),
                    )
            return ok
        if effect is None:
            return True
        receipt = None
        try:
            receipt = self._validated_effect_receipt(
                effect, self._executor.execute(effect), not_before=now
            )
        except Exception:
            reconciler = getattr(self._executor, "reconcile", None)
            if callable(reconciler):
                try:
                    receipt = self._validated_effect_receipt(
                        effect, reconciler(effect), not_before=now
                    )
                except Exception:
                    receipt = None
        if receipt is None:
            with self.db.transaction() as connection:
                self._finish_step(
                    connection,
                    effect.stepId,
                    "uncertain",
                    "reconciliation_required",
                    int(self.settings.clock()),
                )
                connection.execute(
                    "UPDATE power_recovery_runs SET state='failed',failure_code='effect_failed',updated_at=? WHERE run_id=?",
                    (int(self.settings.clock()), effect.runId),
                )
            return False
        with self.db.transaction() as connection:
            self._finish_step(connection, effect.stepId, "succeeded", "completed", receipt.completedAt)
        return True
