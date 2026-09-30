"""F49 normal Core acceptance against real TCP HA/OpenSprinkler fixtures."""

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.garden_irrigation.home_assistant import _revision
from support.f49_irrigation_fixture import (
    IrrigationFixture,
    configure_irrigation,
    provision_inventory,
    source_body,
)


@pytest.fixture
def irrigation_upstream(server):
    upstream = IrrigationFixture(server[3].now)
    yield upstream
    upstream.close()
    assert upstream.errors == []


def configured(server, upstream):
    app, client, _settings, _clock = server
    actor = ready(server)
    service, room = provision_inventory(client, app.state.core, actor, upstream)
    source, zone, controller = configure_irrigation(
        client, actor, upstream, service, room
    )
    return app, client, actor, service, room, source, zone, controller


def test_digest_revision_is_above_32_bit_and_exactly_js_safe():
    value = _revision({"fixture": "f49-js-safe"})
    assert 2**31 < value <= 2**52


def test_source_and_controller_survive_restart_with_js_safe_observations(
    server, irrigation_upstream
):
    _app, client, actor, _service, _room, source, _zone, controller = configured(
        server, irrigation_upstream
    )
    headers = auth(actor)

    with TestClient(create_app(server[2])) as restarted:
        stored_source = restarted.get(
            "/api/v1/admin/irrigation-budget/source", headers=headers
        )
        stored_controller = restarted.get(
            "/api/v1/admin/irrigation-budget/controller", headers=headers
        )
        snapshot = restarted.get(
            "/api/v1/admin/irrigation-budget", headers=headers
        )

    assert stored_source.status_code == 200, stored_source.text
    assert stored_source.json()["source"] == source
    assert stored_controller.status_code == 200, stored_controller.text
    assert stored_controller.json()["controller"] == controller
    assert snapshot.status_code == 200, snapshot.text
    value = snapshot.json()["snapshot"]
    assert value["controlCapability"] == "verified_control"
    assert 2**31 < value["budget"]["revision"] <= 2**52
    assert 2**31 < value["zones"][0]["soilReadingRevision"] <= 2**52
    assert irrigation_upstream.command_calls == []


def preview(client, actor):
    headers = auth(actor)
    snapshot_response = client.get(
        "/api/v1/admin/irrigation-budget", headers=headers
    )
    assert snapshot_response.status_code == 200, snapshot_response.text
    snapshot = snapshot_response.json()["snapshot"]
    assert snapshot["controlCapability"] == "verified_control"
    assert snapshot["commandEndpointAvailable"] is True
    assert snapshot["rainMilliMm"] == 1_250
    assert snapshot["budget"]["usedMl"] == 12_500
    assert snapshot["budget"]["plannedMl"] == 30_000
    assert snapshot["zones"][0]["durationSeconds"] == 450
    result = client.post(
        "/api/v1/admin/irrigation-budget/preview",
        headers=headers,
        json={
            "schemaVersion": 1,
            "requestId": "e" * 32,
            "expectedPlanId": snapshot["planId"],
            "expectedPolicyRevision": snapshot["policyRevision"],
            "expectedBudgetRevision": snapshot["budget"]["revision"],
        },
    )
    assert result.status_code == 200, result.text
    return snapshot, result.json()["preview"]


def confirm(client, actor, value):
    return client.post(
        "/api/v1/admin/irrigation-budget/confirm",
        headers=auth(actor),
        json={
            "schemaVersion": 1,
            "previewId": value["previewId"],
            "confirmToken": value["confirmToken"],
        },
    )


def test_normal_core_reads_ha_and_returns_actual_timer_flow_receipt_once(
    server, irrigation_upstream
):
    _app, client, actor, *_ = configured(server, irrigation_upstream)
    snapshot, value = preview(client, actor)
    result = confirm(client, actor, value)
    assert result.status_code == 200, result.text
    receipt = result.json()["receipt"]
    assert receipt["status"] == "applied"
    assert receipt["planId"] == snapshot["planId"]
    assert receipt["results"][0]["status"] == "applied"
    assert receipt["results"][0]["readback"]["flowVerified"] is True
    assert receipt["results"][0]["readback"]["deliveredMl"] == 30_000
    assert len(irrigation_upstream.command_calls) == 1

    replay = confirm(client, actor, value)
    assert replay.status_code == 200, replay.text
    assert replay.json()["receipt"] == receipt
    assert len(irrigation_upstream.command_calls) == 1


def test_lost_tcp_ack_reconciles_actual_effect_and_never_replays(
    server, irrigation_upstream
):
    _app, client, actor, *_ = configured(server, irrigation_upstream)
    _snapshot, value = preview(client, actor)
    irrigation_upstream.lose_next_run_ack = True

    first = confirm(client, actor, value)
    assert first.status_code == 200, first.text
    receipt = first.json()["receipt"]
    assert receipt["status"] == "applied"
    assert receipt["results"][0]["readback"]["flowVerified"] is True
    assert len(irrigation_upstream.command_calls) == 1

    second = confirm(client, actor, value)
    assert second.status_code == 200, second.text
    assert second.json()["receipt"] == receipt
    assert len(irrigation_upstream.command_calls) == 1


@pytest.mark.parametrize("drift", ["source", "session"])
def test_source_or_session_drift_before_tcp_command_prevents_write(
    server, irrigation_upstream, drift
):
    app, client, actor, service, room, _source, _zone, _controller = configured(
        server, irrigation_upstream
    )
    _snapshot, value = preview(client, actor)
    principal = app.state.core.auth.authenticate(actor["accessToken"])

    def change_source():
        replacement = source_body(service, room, expected_revision=1)
        replacement["dailyLimitMl"] = 90_000
        app.state.core.irrigation._provider.source_store.put(
            principal, replacement
        )

    def revoke_session():
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE session_families SET revoked_at=? WHERE id=?",
                (app.state.core.settings.clock(), principal.family_id),
            )

    # Confirm performs one capability snapshot, then the worker's pre-dispatch
    # snapshot. Drift on the latter is caught by the post-read and send guard.
    irrigation_upstream.after_controller_snapshots(
        2, change_source if drift == "source" else revoke_session
    )
    response = confirm(client, actor, value)
    assert response.status_code == 200, response.text
    receipt = response.json()["receipt"]
    assert receipt["status"] == "unknown"
    assert receipt["results"][0]["code"] == "worker_ack_unknown"
    assert receipt["results"][0]["readback"] is None
    assert irrigation_upstream.command_calls == []
