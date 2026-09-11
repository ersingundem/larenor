"""Durable dispatch from the encrypted Seerr job to the private worker."""

import time

from conftest import auth
from larenor_server.plugins.seerr_bootstrap_executor import (
    SeerrBootstrapExecutionError,
    SeerrBootstrapExecutionResult,
)
from test_seerr_bootstrap_jobs import BASE, ready_stack, request
from test_seerr_initial_admin import API_KEY
from larenor_server.plugins.seerr_arr_wiring import SeerrArrWiringResult
from larenor_server.plugins.seerr_initialization import SeerrInitializationResult


STEPS = (
    "uninitialized_verified",
    "admin_created",
    "api_key_verified",
    "session_destroyed",
    "arr_wiring_verified",
    "initialization_verified",
)


class Backend:
    def __init__(self, result=None):
        self.calls = []
        self.result = result or SeerrBootstrapExecutionResult(
            "verified",
            API_KEY,
            STEPS,
            SeerrArrWiringResult("verified", ("radarr", "sonarr"), (7, 8)),
            SeerrInitializationResult("verified", True, (
                "uninitialized_verified", "initialize_sent", "initialized_verified"
            )),
        )

    def bootstrap_seerr(self, job, plan, private, *, deadline, gate):
        self.calls.append((job, plan, private, deadline, gate))
        assert deadline > time.monotonic() and gate()
        if isinstance(self.result, BaseException):
            raise self.result
        return self.result


def queued(server, backend=None):
    app, client, _, _ = server
    pair, source, seerr = ready_stack(server)
    selected = backend or Backend()
    app.state.core.seerr_bootstraps.backend = selected
    record = client.post(BASE, headers=auth(pair), json=request(source, seerr))
    assert record.status_code == 201, record.text
    return pair, record.json()["bootstrap"], selected


def test_tick_dispatches_exact_private_job_and_persists_api_key_encrypted(server):
    app, _client, settings, _ = server
    pair, record, backend = queued(server)
    terminal = app.state.core.seerr_bootstraps.tick()["bootstrap"]
    assert terminal == record | {
        "revision": 3,
        "state": "succeeded",
        "phase": "complete",
        "convergencePhase": "verified",
        "arrWired": True,
        "initialized": True,
    }
    assert len(backend.calls) == 1
    job, plan, private, _deadline, _gate = backend.calls[0]
    assert job == record["id"]
    assert plan.templateId == "media"
    assert private.sourceBootstrapId == record["sourceBootstrapId"]
    assert tuple(item.serviceId for item in private.arrBindings) == ("radarr", "sonarr")
    assert all(item.configurationRevision == 3 for item in private.arrBindings)
    stored = app.state.core.seerr_bootstraps.private_payload(record["id"])
    assert stored.api_key == API_KEY
    assert API_KEY not in repr(stored) + repr(terminal)
    with app.state.core.db.connection() as connection:
        ciphertext = connection.execute(
            "SELECT ciphertext FROM media_seerr_bootstraps WHERE id=?", (record["id"],)
        ).fetchone()[0]
    assert API_KEY.encode() not in ciphertext
    assert app.state.core.seerr_bootstraps.tick() is None
    from fastapi.testclient import TestClient
    from larenor_server.app import create_app

    restarted = create_app(settings)
    with TestClient(restarted) as reopened:
        assert reopened.get(
            BASE + "/" + record["id"], headers=auth(pair)
        ).json()["bootstrap"] == terminal
        assert restarted.state.core.seerr_bootstraps.tick() is None


def test_arr_revision_drift_fails_closed_before_private_worker_dispatch(server):
    app, _client, _, _ = server
    _, _record, backend = queued(server)
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE media_arr_configurations SET revision=revision+1 "
            "WHERE service_id='radarr'"
        )
    terminal = app.state.core.seerr_bootstraps.tick()["bootstrap"]
    assert terminal["state"] == "needs_attention"
    assert terminal["errorCode"] == "seerr_bootstrap_authority_changed"
    assert backend.calls == []


def test_missing_worker_fails_without_exposing_private_input(server):
    app, _client, _, _ = server
    _, record, _ = queued(server)
    app.state.core.seerr_bootstraps.backend = None
    terminal = app.state.core.seerr_bootstraps.tick()["bootstrap"]
    assert terminal["state"] == "failed"
    assert terminal["phase"] == "complete"
    assert terminal["errorCode"] == "seerr_bootstrap_worker_unavailable"
    assert "credential" not in repr(terminal)
    assert terminal["id"] == record["id"]


def test_uncertain_worker_failure_needs_attention_and_is_not_retried(server):
    failure = SeerrBootstrapExecutionError(
        "seerr_bootstrap_initial_admin_failed",
        completed_steps=("uninitialized_verified",),
        uncertain_effect=True,
        cause_code="seerr_initial_admin_protocol",
    )
    app, _client, _, _ = server
    _, _, backend = queued(server, Backend(failure))
    terminal = app.state.core.seerr_bootstraps.tick()["bootstrap"]
    assert terminal["state"] == "needs_attention"
    assert terminal["errorCode"] == "seerr_bootstrap_initial_admin_failed"
    assert len(backend.calls) == 1
    assert app.state.core.seerr_bootstraps.tick() is None
    assert "seerr_initial_admin_protocol" not in repr(terminal)


def test_initialization_uncertainty_persists_partial_arr_phase_across_restart(server):
    wiring = SeerrArrWiringResult("verified", ("radarr", "sonarr"), (7, 8))
    failure = SeerrBootstrapExecutionError(
        "seerr_bootstrap_initialization_failed",
        completed_steps=STEPS[:-1],
        uncertain_effect=True,
        cause_code="seerr_initialization_protocol",
        api_key=API_KEY,
        arr_wiring=wiring,
    )
    app, client, settings, _ = server
    pair, record, backend = queued(server, Backend(failure))
    terminal = app.state.core.seerr_bootstraps.tick()["bootstrap"]
    assert terminal == record | {
        "revision": 3,
        "state": "needs_attention",
        "phase": "complete",
        "errorCode": "seerr_bootstrap_initialization_failed",
        "convergencePhase": "initialize",
        "arrWired": True,
    }
    assert terminal["initialized"] is False and len(backend.calls) == 1
    assert API_KEY not in repr(terminal) + failure.__repr__()

    from fastapi.testclient import TestClient
    from larenor_server.app import create_app

    with TestClient(create_app(settings)) as reopened:
        restored = reopened.get(BASE + "/" + record["id"], headers=auth(pair))
        assert restored.status_code == 200
        assert restored.json()["bootstrap"] == terminal


def test_running_job_after_restart_becomes_needs_attention_without_dispatch(server):
    app, _client, _, _ = server
    _, record, backend = queued(server)
    with app.state.core.db.transaction() as connection:
        row = app.state.core.seerr_bootstraps._find(connection, record["id"])
        app.state.core.seerr_bootstraps._transition(
            connection,
            row,
            app.state.core.seerr_bootstraps._decode(row),
            state="running",
        )
    terminal = app.state.core.seerr_bootstraps.tick()["bootstrap"]
    assert terminal["state"] == "needs_attention"
    assert terminal["errorCode"] == "seerr_bootstrap_interrupted"
    assert backend.calls == []
