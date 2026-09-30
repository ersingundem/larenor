import hashlib
import hmac
import json
import os
import resource
import sqlite3
import sys
import uuid

from ..errors import ApiError, StartupError
from .runtime import (
    AiDispatch, AiRuntimeError, AiRuntimeObservation, UnavailableAiJobRuntime,
)


MAX_JOBS = 512


class AiResourceService:
    """Persistent admission queue with deterministic, media-aware allocation."""

    def __init__(self, db, auth, settings, key, context, *, runtime=None):
        self.db, self.auth, self.settings, self.context = db, auth, settings, context
        self.runtime = runtime or UnavailableAiJobRuntime()
        self._key = hmac.new(key, b"larenor-ai-resource-v1", hashlib.sha256).digest()

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.context.coreId, self.context.homeId):
            raise ApiError("not_found", 404)

    def _tag(self, domain, values):
        payload = json.dumps(values, separators=(",", ":"), ensure_ascii=True,
                             allow_nan=False).encode("ascii")
        return hmac.new(self._key, domain + b"\0" + payload, hashlib.sha256).hexdigest()

    def _policy_tag(self, row):
        return self._tag(b"policy", [row[name] for name in (
            "revision", "max_memory_mb", "max_cpu_percent",
            "max_concurrent_jobs", "media_cpu_percent", "updated_at")])

    def _job_tag(self, row):
        return self._tag(b"job", [row[name] for name in (
            "id", "owner_id", "family_id", "request_key", "revision", "kind",
            "label", "priority", "memory_mb", "cpu_percent", "state",
            "created_at", "updated_at")])

    def _lease_tag(self, row):
        return self._tag(b"lease", [row[name] for name in (
            "family_id", "owner_id", "expires_at", "updated_at")])

    def _measurement_tag(self, row):
        return self._tag(b"measurement", [row[name] for name in (
            "sequence", "measured_at", "process_memory_mb", "system_load_percent")])

    def _run_tag(self, row):
        return self._tag(b"run", [row[name] for name in (
            "job_id", "dispatch_id", "provider", "phase", "started_at",
            "finished_at", "result_code", "exit_code", "memory_peak_mb", "cpu_millis",
            "output_sha256", "output_bytes", "released_at", "updated_at")])

    @staticmethod
    def _default_policy():
        return {"revision": 1, "max_memory_mb": 2048, "max_cpu_percent": 70,
                "max_concurrent_jobs": 2, "media_cpu_percent": 25,
                "updated_at": 0.0}

    def _policy(self, connection):
        row = connection.execute("SELECT * FROM ai_resource_policy WHERE id=1").fetchone()
        if row is None:
            return self._default_policy()
        if not hmac.compare_digest(row["record_tag"], self._policy_tag(row)):
            raise StartupError("ai_resource_storage_invalid")
        return dict(row)

    def _verified_jobs(self, connection):
        rows = connection.execute(
            "SELECT * FROM ai_resource_jobs ORDER BY priority DESC,created_at,id"
        ).fetchall()
        if any(not hmac.compare_digest(row["record_tag"], self._job_tag(row)) for row in rows):
            raise StartupError("ai_resource_storage_invalid")
        return [dict(row) for row in rows]

    def _verified_leases(self, connection):
        rows = connection.execute("SELECT * FROM ai_resource_media_leases").fetchall()
        if any(not hmac.compare_digest(row["record_tag"], self._lease_tag(row)) for row in rows):
            raise StartupError("ai_resource_storage_invalid")
        return [dict(row) for row in rows]

    def _verified_measurements(self, connection):
        rows = connection.execute("SELECT * FROM ai_resource_measurements ORDER BY sequence").fetchall()
        if any(not hmac.compare_digest(row["record_tag"], self._measurement_tag(row))
               for row in rows):
            raise StartupError("ai_resource_storage_invalid")
        return [dict(row) for row in rows]

    def _verified_runs(self, connection):
        rows = connection.execute(
            "SELECT * FROM ai_resource_runs ORDER BY updated_at,job_id"
        ).fetchall()
        if any(not hmac.compare_digest(row["record_tag"], self._run_tag(row))
               for row in rows):
            raise StartupError("ai_resource_storage_invalid")
        return [dict(row) for row in rows]

    @staticmethod
    def _authority_current(connection, job, now):
        row = connection.execute(
            "SELECT f.revoked_at,f.expires_at,u.disabled,u.must_change_password "
            "FROM session_families f "
            "JOIN users u ON u.id=f.user_id WHERE f.id=? AND u.id=?",
            (job["family_id"], job["owner_id"]),
        ).fetchone()
        return bool(row is not None and not row["disabled"]
                    and not row["must_change_password"]
                    and row["revoked_at"] is None and now < row["expires_at"])

    def validate_storage(self):
        with self.db.connection() as connection:
            self._policy(connection)
            self._verified_jobs(connection)
            self._verified_leases(connection)
            self._verified_measurements(connection)
            self._verified_runs(connection)

    @staticmethod
    def _memory_mb():
        try:
            return max(64, int(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") // 1_048_576))
        except (OSError, ValueError):
            return 64

    @staticmethod
    def _process_memory_mb():
        try:
            with open("/proc/self/statm", encoding="ascii") as stream:
                pages = int(stream.read().split()[1])
            return max(0, pages * os.sysconf("SC_PAGE_SIZE") // 1_048_576)
        except (OSError, ValueError, IndexError):
            value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
            bytes_used = value if sys.platform == "darwin" else value * 1024
            return max(0, int(bytes_used // 1_048_576))

    @staticmethod
    def _system_load_percent():
        try:
            load = os.getloadavg()[0]
        except OSError:
            return 0
        return max(0, min(100, round(load * 100 / max(1, os.cpu_count() or 1))))

    def _record_measurement(self, connection, now):
        memory = self._process_memory_mb()
        load = self._system_load_percent()
        cursor = connection.execute(
            "INSERT INTO ai_resource_measurements(measured_at,process_memory_mb,system_load_percent,record_tag) "
            "VALUES(?,?,?,'')", (now, memory, load))
        row = {"sequence": cursor.lastrowid, "measured_at": now,
               "process_memory_mb": memory, "system_load_percent": load}
        connection.execute("UPDATE ai_resource_measurements SET record_tag=? WHERE sequence=?",
                           (self._measurement_tag(row), row["sequence"]))
        connection.execute(
            "DELETE FROM ai_resource_measurements WHERE sequence IN (SELECT sequence FROM "
            "ai_resource_measurements ORDER BY sequence DESC LIMIT -1 OFFSET 256)"
        )
        return row

    def _public_policy(self, row):
        return {"schemaVersion": 1, "revision": row["revision"],
                "maxMemoryMb": row["max_memory_mb"],
                "maxCpuPercent": row["max_cpu_percent"],
                "maxConcurrentJobs": row["max_concurrent_jobs"],
                "mediaCpuPercent": row["media_cpu_percent"],
                "updatedAt": row["updated_at"]}

    @staticmethod
    def _dispatch(job, run):
        return AiDispatch(
            job["id"], run["dispatch_id"], job["request_key"], job["kind"],
            job["memory_mb"], job["cpu_percent"],
        )

    def _update_job_state(self, connection, row, state, now):
        if row["state"] == state:
            return row
        updated = dict(row)
        updated.update(
            revision=row["revision"] + 1, state=state, updated_at=now,
        )
        cursor = connection.execute(
            "UPDATE ai_resource_jobs SET revision=?,state=?,updated_at=?,record_tag=? "
            "WHERE id=? AND revision=?",
            (updated["revision"], state, now, self._job_tag(updated),
             row["id"], row["revision"]),
        )
        if cursor.rowcount != 1:
            raise ApiError("ai_resource_job_changed", 409)
        return updated

    def _update_run(self, connection, row, now, **changes):
        updated = dict(row)
        updated.update(changes, updated_at=now)
        cursor = connection.execute(
            "UPDATE ai_resource_runs SET phase=?,started_at=?,finished_at=?,"
            "result_code=?,exit_code=?,memory_peak_mb=?,cpu_millis=?,"
            "output_sha256=?,output_bytes=?,released_at=?,updated_at=?,record_tag=? "
            "WHERE job_id=? AND dispatch_id=? AND phase=?",
            (updated["phase"], updated["started_at"], updated["finished_at"],
             updated["result_code"], updated["exit_code"],
             updated["memory_peak_mb"], updated["cpu_millis"],
             updated["output_sha256"], updated["output_bytes"],
             updated["released_at"], now,
             self._run_tag(updated), row["job_id"], row["dispatch_id"],
             row["phase"]),
        )
        return updated if cursor.rowcount == 1 else None

    def _apply_observation(self, job_id, dispatch_id, observation):
        if type(observation) is not AiRuntimeObservation:
            raise AiRuntimeError("invalid_runtime_response")
        now = float(self.settings.clock())
        states = {
            "starting": ("dispatching", "starting"),
            "running": ("running", "running"),
            "cancel_requested": ("cancel_requested", "cancel_requested"),
            "succeeded": ("completed", "succeeded"),
            "failed": ("failed", "failed"),
            "cancelled": ("cancelled", "cancelled"),
            "unknown": ("uncertain", "uncertain"),
        }
        state, phase = states[observation.phase]
        terminal = phase in {"succeeded", "failed", "cancelled"}
        with self.db.transaction() as connection:
            job = connection.execute(
                "SELECT * FROM ai_resource_jobs WHERE id=?", (job_id,),
            ).fetchone()
            run = connection.execute(
                "SELECT * FROM ai_resource_runs WHERE job_id=? AND dispatch_id=?",
                (job_id, dispatch_id),
            ).fetchone()
            if job is None or run is None:
                return
            if (not hmac.compare_digest(job["record_tag"], self._job_tag(job))
                    or not hmac.compare_digest(run["record_tag"], self._run_tag(run))):
                raise StartupError("ai_resource_storage_invalid")
            if run["phase"] in {"succeeded", "failed", "cancelled"}:
                return
            result_code = observation.result_code
            if phase == "uncertain":
                result_code = "runtime_lost"
            updated_run = self._update_run(
                connection, dict(run), now, phase=phase,
                finished_at=now if terminal else None,
                result_code=result_code, exit_code=observation.exit_code,
                memory_peak_mb=observation.memory_peak_mb,
                cpu_millis=observation.cpu_millis,
                output_sha256=observation.output_sha256,
                output_bytes=observation.output_bytes,
            )
            if updated_run is not None:
                self._update_job_state(connection, dict(job), state, now)

    def _claim_start(self, job_id, dispatch_id):
        now = float(self.settings.clock())
        with self.db.transaction() as connection:
            job = connection.execute(
                "SELECT * FROM ai_resource_jobs WHERE id=?", (job_id,),
            ).fetchone()
            run = connection.execute(
                "SELECT * FROM ai_resource_runs WHERE job_id=? AND dispatch_id=?",
                (job_id, dispatch_id),
            ).fetchone()
            if job is None or run is None or run["phase"] != "reserved":
                return None
            if (not hmac.compare_digest(job["record_tag"], self._job_tag(job))
                    or not hmac.compare_digest(run["record_tag"], self._run_tag(run))):
                raise StartupError("ai_resource_storage_invalid")
            if not self._authority_current(connection, job, now):
                self._update_job_state(
                    connection, dict(job), "cancelled", now)
                self._update_run(
                    connection, dict(run), now, phase="cancelled",
                    finished_at=now, result_code="cancelled",
                )
                return None
            updated = self._update_run(
                connection, dict(run), now, phase="starting", started_at=now,
            )
            return None if updated is None else self._dispatch(dict(job), updated)

    def _mark_released(self, job_id, dispatch_id):
        now = float(self.settings.clock())
        with self.db.transaction() as connection:
            run = connection.execute(
                "SELECT * FROM ai_resource_runs WHERE job_id=? AND dispatch_id=?",
                (job_id, dispatch_id),
            ).fetchone()
            if run is None:
                return
            if not hmac.compare_digest(run["record_tag"], self._run_tag(run)):
                raise StartupError("ai_resource_storage_invalid")
            if (run["phase"] in {"succeeded", "failed", "cancelled"}
                    and run["released_at"] is None):
                self._update_run(
                    connection, dict(run), now, released_at=now,
                )

    def _reconcile_authority(self):
        now = float(self.settings.clock())
        with self.db.transaction() as connection:
            jobs = self._verified_jobs(connection)
            runs = {row["job_id"]: row for row in self._verified_runs(connection)}
            for job in jobs:
                if (job["state"] in {"cancelled", "completed", "failed"}
                        or self._authority_current(connection, job, now)):
                    continue
                run = runs.get(job["id"])
                if run is None:
                    self._update_job_state(
                        connection, job, "cancelled", now)
                elif run["phase"] == "reserved":
                    self._update_job_state(
                        connection, job, "cancelled", now)
                    self._update_run(
                        connection, run, now, phase="cancelled",
                        finished_at=now, result_code="cancelled",
                    )
                elif run["phase"] not in {"succeeded", "failed", "cancelled"}:
                    if job["state"] != "cancel_requested":
                        self._update_job_state(
                            connection, job, "cancel_requested", now)
                    if run["phase"] != "cancel_requested":
                        self._update_run(
                            connection, run, now, phase="cancel_requested",
                        )

    def _reserve(self, runtime_available):
        if not runtime_available:
            return []
        now = float(self.settings.clock())
        reserved = []
        with self.db.transaction() as connection:
            policy = self._policy(connection)
            jobs = self._verified_jobs(connection)
            runs = self._verified_runs(connection)
            leases = self._verified_leases(connection)
            media_active = any(row["expires_at"] > now for row in leases)
            memory_limit = min(policy["max_memory_mb"], self._memory_mb())
            cpu_limit = (policy["media_cpu_percent"] if media_active
                         else policy["max_cpu_percent"])
            active = [row for row in jobs if row["state"] in {
                "dispatching", "running", "cancel_requested", "uncertain"}]
            used_memory = sum(row["memory_mb"] for row in active)
            used_cpu = sum(row["cpu_percent"] for row in active)
            running = len(active)
            known_runs = {row["job_id"] for row in runs}
            for job in jobs:
                if (job["state"] != "queued" or job["id"] in known_runs
                        or not self.runtime.supports(job["kind"])
                        or job["memory_mb"] > memory_limit
                        or job["cpu_percent"] > cpu_limit
                        or running >= policy["max_concurrent_jobs"]
                        or used_memory + job["memory_mb"] > memory_limit
                        or used_cpu + job["cpu_percent"] > cpu_limit):
                    continue
                provider = self.runtime.provider(job["kind"])
                if type(provider) is not str:
                    continue
                updated_job = self._update_job_state(
                    connection, job, "dispatching", now)
                run = {
                    "job_id": job["id"], "dispatch_id": uuid.uuid4().hex,
                    "provider": provider, "phase": "reserved",
                    "started_at": None, "finished_at": None,
                    "result_code": None, "exit_code": None,
                    "memory_peak_mb": None, "cpu_millis": None,
                    "output_sha256": None, "output_bytes": None,
                    "released_at": None,
                    "updated_at": now,
                }
                connection.execute(
                    "INSERT INTO ai_resource_runs VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (*[run[name] for name in (
                        "job_id", "dispatch_id", "provider", "phase",
                        "started_at", "finished_at", "result_code", "exit_code",
                        "memory_peak_mb", "cpu_millis", "output_sha256",
                        "output_bytes", "released_at", "updated_at")],
                     self._run_tag(run)),
                )
                reserved.append((updated_job["id"], run["dispatch_id"]))
                running += 1
                used_memory += job["memory_mb"]
                used_cpu += job["cpu_percent"]
        return reserved

    def tick(self):
        try:
            runtime_available = bool(self.runtime.available())
        except Exception:
            runtime_available = False
        self._reconcile_authority()
        with self.db.connection() as connection:
            jobs = {row["id"]: row for row in self._verified_jobs(connection)}
            runs = self._verified_runs(connection)
        if runtime_available:
            pending_starts = []
            for run in runs:
                job = jobs.get(run["job_id"])
                if job is None:
                    continue
                if run["phase"] in {"succeeded", "failed", "cancelled"}:
                    if run["released_at"] is None:
                        try:
                            self.runtime.release(self._dispatch(job, run))
                        except AiRuntimeError:
                            continue
                        self._mark_released(job["id"], run["dispatch_id"])
                    continue
                if run["phase"] == "reserved":
                    dispatch = self._claim_start(job["id"], run["dispatch_id"])
                    if dispatch is not None:
                        pending_starts.append(dispatch)
                    continue
                dispatch = self._dispatch(job, run)
                try:
                    observation = (self.runtime.cancel(dispatch)
                                   if run["phase"] == "cancel_requested"
                                   else self.runtime.observe(dispatch))
                except AiRuntimeError:
                    continue
                self._apply_observation(job["id"], run["dispatch_id"], observation)
            for job_id, dispatch_id in self._reserve(runtime_available):
                dispatch = self._claim_start(job_id, dispatch_id)
                if dispatch is not None:
                    pending_starts.append(dispatch)
            for dispatch in pending_starts:
                try:
                    observation = self.runtime.start(dispatch)
                except AiRuntimeError:
                    observation = AiRuntimeObservation(
                        "unknown", "runtime_lost")
                self._apply_observation(
                    dispatch.job_id, dispatch.dispatch_id, observation)
            self._reconcile_authority()

    def _public_execution(self, run):
        if run is None:
            return None
        return {
            "schemaVersion": 1,
            "dispatchId": run["dispatch_id"],
            "provider": run["provider"],
            "phase": run["phase"],
            "startedAt": run["started_at"],
            "finishedAt": run["finished_at"],
            "resultCode": run["result_code"],
            "exitCode": run["exit_code"],
            "memoryPeakMb": run["memory_peak_mb"],
            "cpuMillis": run["cpu_millis"],
            "outputSha256": run["output_sha256"],
            "outputBytes": run["output_bytes"],
        }

    def _allocate(self, policy, jobs, runs, media_active, runtime_available):
        memory_limit = min(policy["max_memory_mb"], self._memory_mb())
        cpu_limit = policy["media_cpu_percent"] if media_active else policy["max_cpu_percent"]
        active = [row for row in jobs if row["state"] in {
            "dispatching", "running", "cancel_requested", "uncertain"}]
        used_memory = sum(row["memory_mb"] for row in active)
        used_cpu = sum(row["cpu_percent"] for row in active)
        running = len(active)
        run_by_job = {row["job_id"]: row for row in runs}
        output = []
        for row in jobs:
            state, reason = row["state"], None
            if state == "queued":
                if row["memory_mb"] > memory_limit or row["cpu_percent"] > policy["max_cpu_percent"]:
                    state, reason = "blocked", "insufficientHardware"
                elif not runtime_available or not self.runtime.supports(row["kind"]):
                    state, reason = "blocked", "workerUnavailable"
                elif row["cpu_percent"] > cpu_limit:
                    state, reason = "blocked", "mediaActive" if media_active else "quotaExceeded"
                elif (running >= policy["max_concurrent_jobs"] or
                      used_memory + row["memory_mb"] > memory_limit or
                      used_cpu + row["cpu_percent"] > cpu_limit):
                    state, reason = "queued", "higherPriorityWork"
            output.append({"schemaVersion": 1, "id": row["id"],
                           "revision": row["revision"], "kind": row["kind"],
                           "label": row["label"], "priority": row["priority"],
                           "memoryMb": row["memory_mb"], "cpuPercent": row["cpu_percent"],
                           "state": state, "reason": reason,
                           "execution": self._public_execution(run_by_job.get(row["id"])),
                           "ownedByCurrentSession": False,
                           "createdAt": row["created_at"], "updatedAt": row["updated_at"]})
        return output, used_memory, used_cpu

    def snapshot(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        with self.db.connection() as connection:
            self.auth.assert_current(connection, actor)
        self.tick()
        now = float(self.settings.clock())
        try:
            runtime_available = bool(self.runtime.available())
        except Exception:
            runtime_available = False
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            policy = self._policy(connection)
            jobs = self._verified_jobs(connection)
            leases = self._verified_leases(connection)
            self._verified_measurements(connection)
            runs = self._verified_runs(connection)
            measurement = self._record_measurement(connection, now)
        media_active = any(row["expires_at"] > now for row in leases)
        public_jobs, used_memory, used_cpu = self._allocate(
            policy, jobs, runs, media_active, runtime_available)
        for public, row in zip(public_jobs, jobs, strict=True):
            public["ownedByCurrentSession"] = (
                row["owner_id"] == actor.id and row["family_id"] == actor.family_id)
        return {"schemaVersion": 1,
                "scope": {"schemaVersion": 1, "coreId": self.context.coreId,
                          "homeId": self.context.homeId},
                "policy": self._public_policy(policy),
                "capacity": {"memoryMb": self._memory_mb(),
                             "cpuCount": max(1, os.cpu_count() or 1),
                             "effectiveCpuPercent": (policy["media_cpu_percent"]
                                                     if media_active else policy["max_cpu_percent"]),
                             "allocatedMemoryMb": used_memory,
                             "allocatedCpuPercent": used_cpu,
                             "processMemoryMb": measurement["process_memory_mb"],
                             "systemLoadPercent": measurement["system_load_percent"],
                             "measuredAt": measurement["measured_at"],
                             "mediaActive": media_active,
                             "workerAvailable": runtime_available,
                             "enforcement": (self.runtime.enforcement
                                             if runtime_available else "unavailable")},
                "jobs": public_jobs[-MAX_JOBS:]}

    def update_policy(self, actor, core_id, home_id, body):
        self._scope(core_id, home_id)
        now = float(self.settings.clock())
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            if actor.role != "admin":
                raise ApiError("forbidden", 403)
            old = self._policy(connection)
            if old["revision"] != body.expectedRevision:
                raise ApiError("ai_resource_policy_changed", 409)
            row = {"revision": old["revision"] + 1,
                   "max_memory_mb": body.maxMemoryMb,
                   "max_cpu_percent": body.maxCpuPercent,
                   "max_concurrent_jobs": body.maxConcurrentJobs,
                   "media_cpu_percent": body.mediaCpuPercent,
                   "updated_at": now}
            tag = self._policy_tag(row)
            connection.execute(
                "INSERT INTO ai_resource_policy VALUES(1,?,?,?,?,?,?,?) "
                "ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,"
                "max_memory_mb=excluded.max_memory_mb,max_cpu_percent=excluded.max_cpu_percent,"
                "max_concurrent_jobs=excluded.max_concurrent_jobs,"
                "media_cpu_percent=excluded.media_cpu_percent,updated_at=excluded.updated_at,"
                "record_tag=excluded.record_tag",
                (row["revision"], row["max_memory_mb"], row["max_cpu_percent"],
                 row["max_concurrent_jobs"], row["media_cpu_percent"], now, tag))
        return self.snapshot(actor, core_id, home_id)

    def enqueue(self, actor, core_id, home_id, body):
        self._scope(core_id, home_id)
        now = float(self.settings.clock())
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            policy = self._policy(connection)
            if policy["revision"] != body.expectedPolicyRevision:
                raise ApiError("ai_resource_policy_changed", 409)
            old = connection.execute(
                "SELECT * FROM ai_resource_jobs WHERE owner_id=? AND family_id=? AND request_key=?",
                (actor.id, actor.family_id, body.requestKey)).fetchone()
            if old is not None:
                if not hmac.compare_digest(old["record_tag"], self._job_tag(old)):
                    raise StartupError("ai_resource_storage_invalid")
                expected = (body.kind, body.label, body.priority, body.memoryMb, body.cpuPercent)
                observed = tuple(old[name] for name in ("kind", "label", "priority", "memory_mb", "cpu_percent"))
                if observed != expected:
                    raise ApiError("ai_resource_replay_changed", 409)
            else:
                expired = (
                    "SELECT id FROM ai_resource_jobs WHERE state IN "
                    "('cancelled','completed','failed') ORDER BY updated_at DESC,id DESC "
                    "LIMIT -1 OFFSET ?"
                )
                connection.execute(
                    "DELETE FROM ai_resource_runs WHERE job_id IN (" + expired + ")",
                    (MAX_JOBS,),
                )
                connection.execute(
                    "DELETE FROM ai_resource_jobs WHERE id IN (" + expired + ")",
                    (MAX_JOBS,),
                )
                active = connection.execute(
                    "SELECT COUNT(*) AS count FROM ai_resource_jobs WHERE state NOT IN "
                    "('cancelled','completed','failed')"
                ).fetchone()["count"]
                if active >= MAX_JOBS:
                    raise ApiError("ai_resource_job_limit", 413)
                row = {"id": uuid.uuid4().hex, "owner_id": actor.id,
                       "family_id": actor.family_id, "request_key": body.requestKey,
                       "revision": 1, "kind": body.kind, "label": body.label,
                       "priority": body.priority, "memory_mb": body.memoryMb,
                       "cpu_percent": body.cpuPercent, "state": "queued",
                       "created_at": now, "updated_at": now}
                connection.execute(
                    "INSERT INTO ai_resource_jobs VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (*[row[name] for name in ("id", "owner_id", "family_id", "request_key",
                       "revision", "kind", "label", "priority", "memory_mb", "cpu_percent",
                       "state", "created_at", "updated_at")], self._job_tag(row)))
        return self.snapshot(actor, core_id, home_id)

    def cancel(self, actor, core_id, home_id, job_id, body):
        self._scope(core_id, home_id)
        now = float(self.settings.clock())
        dispatch = None
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            old = connection.execute("SELECT * FROM ai_resource_jobs WHERE id=?", (job_id,)).fetchone()
            if old is None:
                raise ApiError("not_found", 404)
            if not hmac.compare_digest(old["record_tag"], self._job_tag(old)):
                raise StartupError("ai_resource_storage_invalid")
            if old["revision"] != body.expectedRevision:
                raise ApiError("ai_resource_job_changed", 409)
            if actor.role != "admin" and (old["owner_id"], old["family_id"]) != (actor.id, actor.family_id):
                raise ApiError("forbidden", 403)
            if old["state"] == "cancelled":
                pass
            elif old["state"] == "queued":
                self._update_job_state(connection, dict(old), "cancelled", now)
            elif old["state"] in {
                    "dispatching", "running", "cancel_requested", "uncertain"}:
                run = connection.execute(
                    "SELECT * FROM ai_resource_runs WHERE job_id=?", (job_id,),
                ).fetchone()
                if run is None or not hmac.compare_digest(
                        run["record_tag"], self._run_tag(run)):
                    raise StartupError("ai_resource_storage_invalid")
                if run["phase"] == "reserved":
                    self._update_job_state(
                        connection, dict(old), "cancelled", now)
                    self._update_run(
                        connection, dict(run), now, phase="cancelled",
                        finished_at=now, result_code="cancelled",
                    )
                else:
                    self._update_job_state(
                        connection, dict(old), "cancel_requested", now)
                    updated = self._update_run(
                        connection, dict(run), now, phase="cancel_requested",
                    )
                    if updated is not None:
                        dispatch = self._dispatch(dict(old), updated)
            else:
                raise ApiError("ai_resource_job_changed", 409)
        if dispatch is not None:
            try:
                observation = self.runtime.cancel(dispatch)
            except AiRuntimeError:
                observation = None
            if observation is not None:
                self._apply_observation(job_id, dispatch.dispatch_id, observation)
        return self.snapshot(actor, core_id, home_id)

    def media_activity(self, actor, core_id, home_id, body):
        self._scope(core_id, home_id)
        now = float(self.settings.clock())
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            if not body.active:
                connection.execute("DELETE FROM ai_resource_media_leases WHERE family_id=?", (actor.family_id,))
            else:
                row = {"family_id": actor.family_id, "owner_id": actor.id,
                       "expires_at": now + body.leaseSeconds, "updated_at": now}
                connection.execute(
                    "INSERT INTO ai_resource_media_leases VALUES(?,?,?,?,?) ON CONFLICT(family_id) "
                    "DO UPDATE SET owner_id=excluded.owner_id,expires_at=excluded.expires_at,"
                    "updated_at=excluded.updated_at,record_tag=excluded.record_tag",
                    (row["family_id"], row["owner_id"], row["expires_at"], now,
                     self._lease_tag(row)))
            connection.execute("DELETE FROM ai_resource_media_leases WHERE expires_at<=?", (now,))
        return self.snapshot(actor, core_id, home_id)
