import hashlib
import hmac
import json
import os
import resource
import sqlite3
import sys
import uuid

from ..errors import ApiError, StartupError


MAX_JOBS = 512


class AiResourceService:
    """Persistent admission queue with deterministic, media-aware allocation."""

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings, self.context = db, auth, settings, context
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

    def validate_storage(self):
        with self.db.connection() as connection:
            self._policy(connection)
            self._verified_jobs(connection)
            self._verified_leases(connection)
            self._verified_measurements(connection)

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

    def _allocate(self, policy, jobs, media_active):
        memory_limit = min(policy["max_memory_mb"], self._memory_mb())
        cpu_limit = policy["media_cpu_percent"] if media_active else policy["max_cpu_percent"]
        used_memory = used_cpu = running = 0
        output = []
        for row in jobs:
            state, reason = row["state"], None
            if state == "queued":
                if row["memory_mb"] > memory_limit or row["cpu_percent"] > policy["max_cpu_percent"]:
                    state, reason = "blocked", "insufficientHardware"
                elif row["cpu_percent"] > cpu_limit:
                    state, reason = "blocked", "mediaActive" if media_active else "quotaExceeded"
                elif (running >= policy["max_concurrent_jobs"] or
                      used_memory + row["memory_mb"] > memory_limit or
                      used_cpu + row["cpu_percent"] > cpu_limit):
                    state, reason = "queued", "higherPriorityWork"
                else:
                    state = "running"
                    running += 1
                    used_memory += row["memory_mb"]
                    used_cpu += row["cpu_percent"]
            output.append({"schemaVersion": 1, "id": row["id"],
                           "revision": row["revision"], "kind": row["kind"],
                           "label": row["label"], "priority": row["priority"],
                           "memoryMb": row["memory_mb"], "cpuPercent": row["cpu_percent"],
                           "state": state, "reason": reason,
                           "ownedByCurrentSession": False,
                           "createdAt": row["created_at"], "updatedAt": row["updated_at"]})
        return output, used_memory, used_cpu

    def snapshot(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        now = float(self.settings.clock())
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            policy = self._policy(connection)
            jobs = self._verified_jobs(connection)
            leases = self._verified_leases(connection)
            self._verified_measurements(connection)
            measurement = self._record_measurement(connection, now)
        media_active = any(row["expires_at"] > now for row in leases)
        public_jobs, used_memory, used_cpu = self._allocate(policy, jobs, media_active)
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
                             "mediaActive": media_active},
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
                connection.execute(
                    "DELETE FROM ai_resource_jobs WHERE id IN ("
                    "SELECT id FROM ai_resource_jobs WHERE state IN ('cancelled','completed') "
                    "ORDER BY updated_at DESC,id DESC LIMIT -1 OFFSET ?)",
                    (MAX_JOBS,),
                )
                active = connection.execute(
                    "SELECT COUNT(*) AS count FROM ai_resource_jobs WHERE state='queued'"
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

    def _change(self, actor, core_id, home_id, job_id, expected, state):
        self._scope(core_id, home_id)
        now = float(self.settings.clock())
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, actor)
            old = connection.execute("SELECT * FROM ai_resource_jobs WHERE id=?", (job_id,)).fetchone()
            if old is None:
                raise ApiError("not_found", 404)
            if not hmac.compare_digest(old["record_tag"], self._job_tag(old)):
                raise StartupError("ai_resource_storage_invalid")
            if old["revision"] != expected:
                raise ApiError("ai_resource_job_changed", 409)
            if actor.role != "admin" and (old["owner_id"], old["family_id"]) != (actor.id, actor.family_id):
                raise ApiError("forbidden", 403)
            if old["state"] not in (state, "queued"):
                raise ApiError("ai_resource_job_changed", 409)
            if old["state"] != state:
                row = dict(old); row.update(revision=old["revision"] + 1, state=state, updated_at=now)
                connection.execute(
                    "UPDATE ai_resource_jobs SET revision=?,state=?,updated_at=?,record_tag=? WHERE id=? AND revision=?",
                    (row["revision"], state, now, self._job_tag(row), job_id, expected))
        return self.snapshot(actor, core_id, home_id)

    def cancel(self, actor, core_id, home_id, job_id, body):
        return self._change(actor, core_id, home_id, job_id, body.expectedRevision, "cancelled")

    def complete(self, actor, core_id, home_id, job_id, body):
        return self._change(actor, core_id, home_id, job_id, body.expectedRevision, "completed")

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
