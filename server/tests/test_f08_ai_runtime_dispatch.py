import hashlib
import sqlite3
import time

from conftest import auth, ready

from larenor_server.ai_resources.runtime import AiRuntimeObservation
from larenor_server.ai_resources.schema import (
    _V1_INDEXES, _V1_TABLES, migrate_ai_resources,
)


class Runtime:
    enforcement = "systemdCgroupV2"

    def __init__(self):
        self.online = True
        self.started = []
        self.cancelled = []
        self.released = []
        self.observations = {}

    def available(self):
        return self.online

    def supports(self, kind):
        return kind == "assistant"

    def provider(self, kind):
        return "fixture-standalone-v1" if self.supports(kind) else None

    def start(self, dispatch):
        self.started.append(dispatch)
        observation = AiRuntimeObservation(
            "running", memory_peak_mb=17, cpu_millis=9,
        )
        self.observations[dispatch.dispatch_id] = observation
        return observation

    def observe(self, dispatch):
        return self.observations[dispatch.dispatch_id]

    def cancel(self, dispatch):
        self.cancelled.append(dispatch.dispatch_id)
        observation = AiRuntimeObservation(
            "cancelled", "cancelled", 15, 18, 12,
        )
        self.observations[dispatch.dispatch_id] = observation
        return observation

    def release(self, dispatch):
        self.released.append(dispatch.dispatch_id)


def _root(app):
    context = app.state.core.context
    return f"/api/v1/ai-resources/{context.coreId}/{context.homeId}"


def _job(request_key):
    return {
        "schemaVersion": 1,
        "expectedPolicyRevision": 1,
        "requestKey": request_key,
        "kind": "assistant",
        "label": "Local standalone assistant",
        "priority": 100,
        "memoryMb": 64,
        "cpuPercent": 30,
    }


def test_real_runtime_reservation_persists_running_and_terminal_readback(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    runtime = Runtime()
    app.state.core.ai_resources.runtime = runtime
    root = _root(app)

    response = client.post(
        root + "/jobs", headers=auth(pair),
        json=_job("standalone-runtime-job-0001"),
    )
    assert response.status_code == 200, response.text
    job = response.json()["jobs"][0]
    assert job["state"] == "running"
    assert job["execution"]["provider"] == "fixture-standalone-v1"
    assert job["execution"]["phase"] == "running"
    assert response.json()["capacity"]["workerAvailable"] is True
    assert response.json()["capacity"]["enforcement"] == "systemdCgroupV2"
    assert len(runtime.started) == 1
    with app.state.core.db.connection() as connection:
        stored = connection.execute(
            "SELECT state FROM ai_resource_jobs WHERE id=?", (job["id"],),
        ).fetchone()
    assert stored["state"] == "running"

    dispatch = runtime.started[0]
    output = b"actual-local-provider-output"
    runtime.observations[dispatch.dispatch_id] = AiRuntimeObservation(
        "succeeded", "succeeded", 0, 61, 425,
        hashlib.sha256(output).hexdigest(), len(output),
    )
    completed = client.get(root, headers=auth(pair))
    assert completed.status_code == 200
    terminal = completed.json()["jobs"][0]
    assert terminal["state"] == "completed"
    assert terminal["execution"]["resultCode"] == "succeeded"
    assert terminal["execution"]["memoryPeakMb"] == 61
    assert terminal["execution"]["cpuMillis"] == 425
    assert terminal["execution"]["outputSha256"] == hashlib.sha256(output).hexdigest()
    assert len(runtime.started) == 1


def test_cancel_intent_is_durable_before_runtime_and_never_restarts(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    runtime = Runtime()
    app.state.core.ai_resources.runtime = runtime
    root = _root(app)
    created = client.post(
        root + "/jobs", headers=auth(pair),
        json=_job("standalone-runtime-job-0002"),
    ).json()["jobs"][0]
    cancelled = client.post(
        f"{root}/jobs/{created['id']}/cancel", headers=auth(pair),
        json={"schemaVersion": 1, "expectedRevision": created["revision"]},
    )
    assert cancelled.status_code == 200, cancelled.text
    job = cancelled.json()["jobs"][0]
    assert job["state"] == "cancelled"
    assert job["execution"]["resultCode"] == "cancelled"
    assert runtime.cancelled == [created["execution"]["dispatchId"]]
    client.get(root, headers=auth(pair))
    assert len(runtime.started) == 1


def test_unconfigured_core_never_fabricates_running_state(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    root = _root(app)
    response = client.post(
        root + "/jobs", headers=auth(pair),
        json=_job("unavailable-runtime-job-0003"),
    )
    job = response.json()["jobs"][0]
    assert job["state"] == "blocked"
    assert job["reason"] == "workerUnavailable"
    assert job["execution"] is None
    assert response.json()["capacity"]["workerAvailable"] is False
    assert response.json()["capacity"]["enforcement"] == "unavailable"
    with app.state.core.db.connection() as connection:
        stored = connection.execute(
            "SELECT state FROM ai_resource_jobs WHERE id=?", (job["id"],),
        ).fetchone()
    assert stored["state"] == "queued"


def test_background_dispatcher_recovers_queued_job_when_worker_appears(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    runtime = Runtime()
    runtime.online = False
    app.state.core.ai_resources.runtime = runtime
    root = _root(app)
    queued = client.post(
        root + "/jobs", headers=auth(pair),
        json=_job("worker-recovery-job-0004"),
    ).json()["jobs"][0]
    assert queued["state"] == "blocked"
    assert queued["reason"] == "workerUnavailable"

    runtime.online = True
    deadline = time.monotonic() + 3
    stored_state = "queued"
    while time.monotonic() < deadline:
        with app.state.core.db.connection() as connection:
            stored_state = connection.execute(
                "SELECT state FROM ai_resource_jobs WHERE id=?", (queued["id"],),
            ).fetchone()["state"]
        if stored_state == "running":
            break
        time.sleep(0.05)
    assert stored_state == "running"
    assert len(runtime.started) == 1


def test_restart_claims_durable_reserved_dispatch_exactly_once(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    runtime = Runtime()
    runtime.online = False
    service = app.state.core.ai_resources
    service.runtime = runtime
    root = _root(app)
    queued = client.post(
        root + "/jobs", headers=auth(pair),
        json=_job("reserved-restart-job-0005"),
    ).json()["jobs"][0]
    reserved = service._reserve(True)
    assert len(reserved) == 1
    with app.state.core.db.connection() as connection:
        run = connection.execute(
            "SELECT phase FROM ai_resource_runs WHERE job_id=?", (queued["id"],),
        ).fetchone()
    assert run["phase"] == "reserved"

    runtime.online = True
    service.tick()
    service.tick()
    assert len(runtime.started) == 1
    with app.state.core.db.connection() as connection:
        stored = connection.execute(
            "SELECT state FROM ai_resource_jobs WHERE id=?", (queued["id"],),
        ).fetchone()
    assert stored["state"] == "running"


def test_reserved_dispatch_cancels_without_contacting_runtime(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    runtime = Runtime()
    runtime.online = False
    service = app.state.core.ai_resources
    service.runtime = runtime
    root = _root(app)
    queued = client.post(
        root + "/jobs", headers=auth(pair),
        json=_job("reserved-cancel-job-0006"),
    ).json()["jobs"][0]
    reserved = service._reserve(True)
    assert len(reserved) == 1 and reserved[0][0] == queued["id"]
    dispatching = client.get(root, headers=auth(pair)).json()["jobs"][0]
    assert dispatching["state"] == "dispatching"
    cancelled = client.post(
        f"{root}/jobs/{queued['id']}/cancel", headers=auth(pair),
        json={"schemaVersion": 1, "expectedRevision": dispatching["revision"]},
    )
    assert cancelled.status_code == 200, cancelled.text
    terminal = cancelled.json()["jobs"][0]
    assert terminal["state"] == "cancelled"
    assert terminal["execution"]["phase"] == "cancelled"
    assert terminal["execution"]["resultCode"] == "cancelled"
    assert runtime.cancelled == []


def test_v1_queue_migrates_to_durable_dispatch_schema():
    connection = sqlite3.connect(":memory:")
    connection.row_factory = sqlite3.Row
    connection.execute("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT)")
    connection.execute("INSERT INTO metadata VALUES('ai_resource_schema','1')")
    for statement in _V1_TABLES.values():
        connection.execute(statement)
    for statement in _V1_INDEXES.values():
        connection.execute(statement)
    connection.execute(
        "INSERT INTO ai_resource_jobs VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        ("1" * 32, "2" * 32, "3" * 32, "migration-job-key-0001", 1,
         "assistant", "Migrated job", 50, 64, 25, "queued", 1.0, 1.0,
         "legacy-tag"),
    )
    migrate_ai_resources(connection)
    assert connection.execute(
        "SELECT value FROM metadata WHERE key='ai_resource_schema'"
    ).fetchone()["value"] == "2"
    assert connection.execute(
        "SELECT state FROM ai_resource_jobs WHERE id=?", ("1" * 32,),
    ).fetchone()["state"] == "queued"
    assert connection.execute(
        "SELECT COUNT(*) AS count FROM ai_resource_runs"
    ).fetchone()["count"] == 0


def test_revoked_session_cancels_running_provider_before_further_work(server):
    app, client, _settings, clock = server
    pair = ready(server)
    runtime = Runtime()
    service = app.state.core.ai_resources
    service.runtime = runtime
    root = _root(app)
    running = client.post(
        root + "/jobs", headers=auth(pair),
        json=_job("revoked-runtime-job-0007"),
    ).json()["jobs"][0]
    assert running["state"] == "running"
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE session_families SET revoked_at=? WHERE id=?",
            (clock.now, pair["sessionFamilyId"]),
        )
    service.tick()
    with app.state.core.db.connection() as connection:
        stored = connection.execute(
            "SELECT state FROM ai_resource_jobs WHERE id=?", (running["id"],),
        ).fetchone()
    assert stored["state"] == "cancelled"
    assert runtime.cancelled == [running["execution"]["dispatchId"]]
    assert len(runtime.started) == 1
