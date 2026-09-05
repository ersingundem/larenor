"""Durable read-only requirements jobs against synthetic workers and private DBs."""

import json
from concurrent.futures import ThreadPoolExecutor
from threading import Event

import pytest

from conftest import auth, login, ready
from test_plugin_api import preview
from larenor_server.errors import ApiError, StartupError
from larenor_server.plugins.job_models import CancelJobRequest, CreateJobRequest
from larenor_server.plugins.job_schema import migrate_plugin_jobs
from larenor_server.plugins.jobs import JobManagement


class Backend:
    def __init__(self):
        self.calls = []
        self.action = None

    def inspect(self, plan):
        from larenor_server.plugins.preflight_models import PreflightResult
        self.calls.append(plan)
        if self.action:
            return self.action(plan)
        return PreflightResult.model_validate({
            "catalogDigest": plan.catalogDigest, "planHash": plan.planHash,
            "platform": plan.platform, "checkedAt": "2026-09-05T12:00:00.000Z",
            "checks": [{"code": "docker_engine", "status": "failed"}],
        })


@pytest.fixture
def jobs(server):
    app, client, settings, clock = server
    pair = ready(server)
    core = app.state.core
    with core.db.transaction() as connection:
        migrate_plugin_jobs(connection)
    backend = Backend()
    manager = JobManagement(core.db, core.auth, settings, settings.key_file.read_bytes(), core.plugins, backend)
    actor = core.auth.authenticate(pair["accessToken"])
    return manager, backend, actor, pair


def submission(server, pair, *, request_id="a" * 32):
    record = preview(server[1], pair)
    return CreateJobRequest(operation="preflight", previewId=record["id"],
                            expectedRevision=1, planHash=record["plan"]["planHash"], requestId=request_id)


def create(server, jobs, **kwargs):
    manager, _, actor, pair = jobs
    return manager.create(actor, submission(server, pair, **kwargs))["job"]


def expect_error(code, fn):
    with pytest.raises(ApiError) as caught:
        fn()
    assert caught.value.code == code


def test_job_records_are_durable_encrypted_and_never_claim_installation(server, jobs):
    manager, backend, actor, _ = jobs
    job = create(server, jobs)
    assert job["state"] == job["phase"] == "queued"
    assert job["revision"] == 1 and job["operation"] == "preflight"
    assert "plan" not in job and job["result"] is None
    assert backend.calls == []
    with manager.db.connection() as connection:
        row = connection.execute("SELECT * FROM plugin_jobs").fetchone()
        assert b'"mounts"' not in row["ciphertext"]
        assert job["planHash"].encode() not in row["ciphertext"]
        assert len(row["nonce"]) == 12
    restarted = JobManagement(manager.db, manager.auth, manager.settings, server[2].key_file.read_bytes(), manager.previews, backend)
    restarted.validate_storage()
    assert restarted.get(actor, job["id"])["job"] == job
    result = restarted.tick()["job"]
    assert result["state"] == "succeeded" and result["phase"] == "complete"
    assert result["result"].checks[0].status == "failed"  # Inspection completed; requirement did not pass.
    assert backend.calls[0].installable is False
    assert [item["code"] for item in restarted.events(actor, job["id"])["events"]] == ["job_queued", "job_started", "job_completed"]


def test_request_id_is_durable_idempotent_after_preview_expiry(server, jobs):
    manager, backend, actor, pair = jobs
    body = submission(server, pair)
    first = manager.create(actor, body)
    server[3].now += 600
    assert manager.create(actor, body) == first
    assert manager.tick()["job"]["state"] == "succeeded"
    assert len(backend.calls) == 1
    assert manager.create(actor, body)["job"]["state"] == "succeeded"


def test_request_id_payload_mismatch_and_second_job_for_preview_conflict(server, jobs):
    manager, _, actor, pair = jobs
    body = submission(server, pair)
    manager.create(actor, body)
    expect_error("plugin_job_conflict", lambda: manager.create(actor, body.model_copy(update={"planHash": "0" * 64})))
    expect_error("plugin_job_conflict", lambda: manager.create(actor, body.model_copy(update={"requestId": "b" * 32})))


def test_concurrent_retries_commit_exactly_one_job(server, jobs):
    manager, _, actor, pair = jobs
    body = submission(server, pair)
    with ThreadPoolExecutor(max_workers=4) as pool:
        values = list(pool.map(lambda _: manager.create(actor, body), range(4)))
    assert len({item["job"]["id"] for item in values}) == 1
    assert len(manager.list(actor)["jobs"]) == 1


@pytest.mark.parametrize("change,code", [({"expectedRevision": 2}, "revision_conflict"),
                                        ({"planHash": "0" * 64}, "plugin_catalog_changed")])
def test_creation_binds_exact_preview_revision_and_plan(server, jobs, change, code):
    manager, _, actor, pair = jobs
    body = submission(server, pair).model_copy(update=change)
    expect_error(code, lambda: manager.create(actor, body))


def test_expired_preview_and_unconfigured_backend_cannot_admit_jobs(server, jobs):
    manager, _, actor, pair = jobs
    body = submission(server, pair)
    manager.backend = None
    assert manager.capabilities(actor) == {"preflightConfigured": False, "installAvailable": False}
    expect_error("plugin_worker_unavailable", lambda: manager.create(actor, body))
    manager.backend = Backend()
    server[3].now += 600
    expect_error("plugin_preview_expired", lambda: manager.create(actor, body))


@pytest.mark.parametrize("bound", ["MAX_QUEUED", "MAX_JOBS"])
def test_queue_and_history_capacity_are_atomic(server, jobs, monkeypatch, bound):
    import larenor_server.plugins.jobs as module
    manager, _, actor, pair = jobs
    monkeypatch.setattr(module, bound, 1)
    bodies = [submission(server, pair, request_id=f"{index:032x}") for index in range(2)]
    def submit(body):
        try:
            return manager.create(actor, body)["job"]["state"]
        except ApiError as error:
            return error.code
    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(submit, bodies)) == ["plugin_job_limit_reached", "queued"]


def test_queued_cancel_is_terminal_and_optimistically_versioned(server, jobs):
    manager, backend, actor, _ = jobs
    job = create(server, jobs)
    expect_error("revision_conflict", lambda: manager.cancel(actor, job["id"], CancelJobRequest(expectedRevision=2)))
    cancelled = manager.cancel(actor, job["id"], CancelJobRequest(expectedRevision=1))["job"]
    assert cancelled["state"] == "cancelled" and cancelled["phase"] == "complete"
    assert cancelled["revision"] == 2
    assert manager.tick() is None and backend.calls == []
    assert manager.cancel(actor, job["id"], CancelJobRequest(expectedRevision=2))["job"] == cancelled


def test_running_cancel_and_inspection_do_not_hold_database_transaction(server, jobs):
    manager, backend, actor, _ = jobs
    job = create(server, jobs)
    started, proceed = Event(), Event()
    original = Backend().inspect
    def blocked(plan):
        started.set()
        assert proceed.wait(5)
        return original(plan)
    backend.action = blocked
    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(manager.tick)
        assert started.wait(5)
        running = manager.get(actor, job["id"])["job"]
        assert running["state"] == "running"
        cancelled = manager.cancel(actor, job["id"], CancelJobRequest(expectedRevision=running["revision"]))["job"]
        assert cancelled["state"] == "running" and cancelled["cancelRequested"] is True
        proceed.set()
        assert pending.result()["job"]["state"] == "cancelled"
    assert manager.get(actor, job["id"])["job"]["result"] is None


def test_only_one_tick_runs_globally_across_manager_instances(server, jobs):
    manager, backend, actor, pair = jobs
    first = create(server, jobs)
    create(server, jobs, request_id="b" * 32)
    second = JobManagement(manager.db, manager.auth, manager.settings, server[2].key_file.read_bytes(), manager.previews, backend)
    started, proceed = Event(), Event()
    original = Backend().inspect
    def blocked(plan):
        started.set()
        assert proceed.wait(5)
        return original(plan)
    backend.action = blocked
    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(manager.tick)
        assert started.wait(5)
        assert second.tick() is None
        assert len(backend.calls) == 1
        proceed.set()
        assert pending.result()["job"]["id"] == first["id"]


@pytest.mark.parametrize("change", ["revoked", "expired", "demoted", "disabled", "revision", "family_removed"])
def test_dispatch_reauthenticates_original_authority_without_access_token(server, jobs, change):
    manager, backend, actor, _ = jobs
    create(server, jobs)
    with manager.db.transaction() as connection:
        if change == "revoked":
            connection.execute("UPDATE session_families SET revoked_at=1 WHERE id=?", (actor.family_id,))
        elif change == "expired":
            connection.execute("UPDATE session_families SET expires_at=1 WHERE id=?", (actor.family_id,))
        elif change == "family_removed":
            connection.execute("DELETE FROM session_tokens WHERE family_id=?", (actor.family_id,))
            connection.execute("DELETE FROM session_families WHERE id=?", (actor.family_id,))
        else:
            field, value = {"demoted": ("role", "member"), "disabled": ("disabled", 1), "revision": ("revision", 99)}[change]
            connection.execute(f"UPDATE users SET {field}=? WHERE id=?", (value, actor.id))
    result = manager.tick()["job"]
    assert result["state"] == "needs_attention" and result["errorCode"] == "authority_changed"
    assert backend.calls == []
    with manager.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM plugin_jobs").fetchone()[0] == 1


def test_normal_access_rotation_does_not_revoke_dispatched_job(server, jobs):
    manager, backend, actor, pair = jobs
    job = create(server, jobs)
    new_pair = manager.auth.refresh(pair["refreshToken"], "fixture")
    assert manager.tick()["job"]["state"] == "succeeded"
    current = manager.auth.authenticate(new_pair["accessToken"])
    assert manager.get(current, job["id"])["job"]["state"] == "succeeded"
    expect_error("invalid_session", lambda: manager.get(actor, job["id"]))


def test_authority_revoked_during_backend_call_cannot_publish_result(server, jobs):
    manager, backend, actor, _ = jobs
    create(server, jobs)
    original = Backend().inspect
    def revoke(plan):
        manager.auth.logout(actor)
        return original(plan)
    backend.action = revoke
    result = manager.tick()["job"]
    assert result["state"] == "needs_attention" and result["result"] is None


@pytest.mark.parametrize("failure", ["exception", "identity", "malformed"])
def test_worker_failures_are_static_and_never_echo_exception_or_paths(server, jobs, failure):
    manager, backend, actor, _ = jobs
    job = create(server, jobs)
    def fail(plan):
        if failure == "exception":
            raise RuntimeError("/private/synthetic-secret/socket")
        result = Backend().inspect(plan)
        return result.model_copy(update={"planHash": "0" * 64}) if failure == "identity" else {"secret": "/private/synthetic-secret"}
    backend.action = fail
    result = manager.tick()["job"]
    assert result["state"] == "failed" and result["result"] is None
    assert result["errorCode"] == ("worker_unavailable" if failure == "exception" else "invalid_worker_result")
    assert "synthetic-secret" not in json.dumps(manager.events(actor, job["id"]))


@pytest.mark.parametrize("field,value", [("ciphertext", b"corrupt"), ("actor_revision", 99),
                                        ("family_id", "f" * 32), ("revision", 2),
                                        ("state", "succeeded"), ("request_id", "f" * 32)])
def test_tampered_jobs_fail_closed_without_worker_call_or_reset(server, jobs, field, value):
    manager, backend, actor, _ = jobs
    job = create(server, jobs)
    with manager.db.connection() as connection:
        connection.execute("PRAGMA ignore_check_constraints=ON")
        connection.execute(f"UPDATE plugin_jobs SET {field}=? WHERE id=?", (value, job["id"]))
    expect_error("plugin_job_storage_unavailable", lambda: manager.get(actor, job["id"]))
    with pytest.raises(StartupError, match="invalid_plugin_jobs_storage"):
        manager.validate_storage()
    expect_error("plugin_job_storage_unavailable", manager.tick)
    assert backend.calls == []


def test_job_and_event_pagination_are_stable_and_bounded(server, jobs):
    manager, _, actor, _ = jobs
    for index in range(3):
        create(server, jobs, request_id=f"{index:032x}")
        manager.tick()
    first = manager.list(actor, limit=2)
    second = manager.list(actor, limit=2, before=first["nextBefore"])
    assert len(first["jobs"]) == 2 and len(second["jobs"]) == 1 and second["nextBefore"] is None
    assert not {job["id"] for job in first["jobs"]} & {job["id"] for job in second["jobs"]}
    event_page = manager.events(actor, first["jobs"][0]["id"], limit=2)
    tail = manager.events(actor, first["jobs"][0]["id"], after=event_page["nextAfter"])
    assert [event["code"] for event in tail["events"]] == ["job_completed"]
    assert tail["nextAfter"] is None


def test_schema_is_additive_and_unknown_or_partial_state_is_rejected(server, jobs):
    manager = jobs[0]
    with manager.db.transaction() as connection:
        migrate_plugin_jobs(connection)
        assert connection.execute("SELECT value FROM metadata WHERE key='plugin_jobs_schema'").fetchone()[0] == "1"
        assert connection.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 1
        connection.execute("UPDATE metadata SET value='9' WHERE key='plugin_jobs_schema'")
    with manager.db.transaction() as connection, pytest.raises(StartupError, match="plugin_jobs_schema_unsupported"):
        migrate_plugin_jobs(connection)
