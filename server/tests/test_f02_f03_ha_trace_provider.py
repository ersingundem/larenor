"""F02/F03 genuine Home Assistant trace ingest and replay evidence."""

import pytest

from conftest import auth, ready
from support.f02_ha_trace_fixture import (
    ENTITY,
    RUN_ID,
    HomeAssistantTraceFixture,
)


@pytest.fixture
def trace_ha():
    value = HomeAssistantTraceFixture()
    yield value
    value.close()


def _setup(server, trace_ha):
    app, client, _settings, _clock = server
    actor = ready(server)
    scope = app.state.core.context
    resource = client.post(
        f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}",
        headers=auth(actor),
        json={"kind": "resource", "label": "Welcome automation", "order": 0},
    ).json()["record"]
    service = client.post("/api/v1/admin/services", headers=auth(actor), json={
        "kind": "home_assistant", "name": "Trace HA", "baseUrl": trace_ha.url,
        "credentials": {"token": "trace-loopback-only"},
    }).json()["service"]
    principal = app.state.core.auth.authenticate(actor["accessToken"])
    app.state.core.services.record_verification(
        principal, service["id"], service["revision"],
        state="authenticated", version="2026.9",
    )
    base = (
        f"/api/v1/admin/home-assistant/{scope.coreId}/{scope.homeId}"
        f"/resources/{resource['ref']['id']}"
    )
    preview = client.post(base + "/binding-preview", headers=auth(actor), json={
        "serviceId": service["id"], "expectedServiceRevision": 1,
        "expectedRevision": 1, "expectedAclRevision": 1,
        "entityId": ENTITY, "expectedBindingId": None,
    }).json()["preview"]
    binding = client.post(
        base + "/binding-confirm", headers=auth(actor),
        json={"previewId": preview["id"]},
    ).json()["binding"]
    root = f"/api/v1/automation-trials/{scope.coreId}/{scope.homeId}"
    trial = client.post(root, headers=auth(actor), json={
        "schemaVersion": 1, "requestKey": "ha-trace-trial-create-0001",
        "timezone": "UTC", "localStartDate": "2026-09-05",
        "rules": [{
            "ruleId": binding["id"], "eventKey": "automation_triggered",
            "deviceId": resource["ref"]["id"], "action": "turn_on",
            "priority": 50, "weekdays": [0, 1, 2, 3, 4, 5, 6],
            "startMinute": 0, "endMinute": 1440,
        }],
    }).json()["trial"]
    return app, client, actor, resource, service, root, trial


def _ingest(client, actor, root, trial, key):
    return client.post(
        f"{root}/{trial['id']}/home-assistant-traces",
        headers=auth(actor),
        json={
            "schemaVersion": 1, "requestKey": key,
            "expectedTrialId": trial["id"],
            "sourceResourceId": trial["rules"][0]["deviceId"],
        },
    )


def test_real_trace_is_authority_bound_redacted_deduped_and_replayable(server, trace_ha):
    _app, client, actor, _resource, _service, root, trial = _setup(server, trace_ha)
    response = _ingest(client, actor, root, trial, "ha-trace-ingest-key-0001")
    assert response.status_code == 201, response.text
    stored = response.json()["trial"]
    assert stored["eventCount"] == 1
    event = stored["events"][0]
    assert event["source"] == "real"
    assert event["evidence"]["provider"] == "home_assistant_trace"
    assert event["evidence"]["runId"] == RUN_ID
    assert event["evidence"]["resourceId"] == trial["rules"][0]["deviceId"]
    assert "NEVER-PUBLISH" not in response.text

    repeated = _ingest(client, actor, root, trial, "ha-trace-ingest-key-0002")
    assert repeated.status_code == 201
    assert repeated.json()["trial"]["eventCount"] == 1
    assert trace_ha.trace_list_calls == trace_ha.trace_get_calls == 2

    replay = client.post(
        f"{root}/{trial['id']}/replays", headers=auth(actor), json={
            "schemaVersion": 1, "expectedTrialId": trial["id"],
            "requiredEventCount": 1,
            "proposedRules": [{**trial["rules"][0], "action": "turn_off"}],
        },
    )
    assert replay.status_code == 200, replay.text
    assert replay.json()["replay"]["status"] == "complete"
    assert replay.json()["replay"]["adapterWriteCount"] == 0
    assert replay.json()["replay"]["queueWriteCount"] == 0


def test_registry_drift_and_untrusted_real_claim_fail_closed(server, trace_ha):
    _app, client, actor, _resource, _service, root, trial = _setup(server, trace_ha)
    direct = client.post(
        f"{root}/{trial['id']}/events", headers=auth(actor), json={
            "schemaVersion": 1, "requestKey": "untrusted-real-event-0001",
            "source": "real", "eventKey": "automation_triggered",
            "occurredAtMs": 1788609540000,
        },
    )
    assert direct.status_code == 409
    assert direct.json()["error"]["code"] == "automation_trial_real_source_required"

    trace_ha.registry_platform = "template"
    drifted = _ingest(client, actor, root, trial, "ha-trace-drift-key-0001")
    assert drifted.status_code == 409
    assert drifted.json()["error"]["code"] == "automation_trial_trace_source_unsupported"
    snapshot = client.get(root, headers=auth(actor)).json()["trials"][0]
    assert snapshot["eventCount"] == 0


def test_session_revocation_during_trace_read_does_not_publish(server, trace_ha):
    app, client, actor, _resource, _service, root, trial = _setup(server, trace_ha)

    def revoke():
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE session_families SET revoked_at=? WHERE id=?",
                (app.state.core.settings.clock(), actor["sessionFamilyId"]),
            )

    trace_ha.after_trace_list = revoke
    response = _ingest(client, actor, root, trial, "ha-trace-revoked-key-0001")
    assert response.status_code in {401, 409}
    with app.state.core.db.connection() as connection:
        count = connection.execute(
            "SELECT COUNT(*) FROM automation_trial_events"
        ).fetchone()[0]
    assert count == 0
    assert trace_ha.trace_get_calls == 0


def test_service_authentication_drift_during_trace_read_does_not_publish(
    server, trace_ha
):
    app, client, actor, _resource, service, root, trial = _setup(server, trace_ha)
    principal = app.state.core.auth.authenticate(actor["accessToken"])

    def downgrade():
        app.state.core.services.record_verification(
            principal, service["id"], service["revision"], state="unavailable"
        )

    trace_ha.after_trace_list = downgrade
    response = _ingest(client, actor, root, trial, "ha-trace-auth-drift-key-0001")
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "ha_binding_changed"
    with app.state.core.db.connection() as connection:
        count = connection.execute(
            "SELECT COUNT(*) FROM automation_trial_events"
        ).fetchone()[0]
    assert count == 0
    assert trace_ha.trace_get_calls == 0


def test_unsupported_trace_command_is_unavailable_not_real_evidence(server, trace_ha):
    app, client, actor, _resource, _service, root, trial = _setup(server, trace_ha)
    trace_ha.trace_supported = False
    response = _ingest(client, actor, root, trial, "ha-trace-unsupported-key-0001")
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "automation_trial_trace_unsupported"
    with app.state.core.db.connection() as connection:
        count = connection.execute(
            "SELECT COUNT(*) FROM automation_trial_events"
        ).fetchone()[0]
    assert count == 0
