"""F07 genuine Home Assistant history anomaly observations."""

import sqlite3

import pytest

from conftest import auth, ready
from larenor_server.habit_anomalies import schema
from support.f07_ha_history_fixture import (
    ENTITY,
    HomeAssistantHistoryFixture,
)


@pytest.fixture
def history_ha():
    value = HomeAssistantHistoryFixture()
    yield value
    value.close()


def _configured(server, fixture):
    app, client, _settings, _clock = server
    actor = ready(server)
    scope = app.state.core.context
    resource = client.post(
        f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}",
        headers=auth(actor),
        json={"kind": "resource", "label": "Hall motion", "order": 0},
    ).json()["record"]
    service = client.post("/api/v1/admin/services", headers=auth(actor), json={
        "kind": "home_assistant", "name": "History HA",
        "baseUrl": fixture.url, "credentials": {"token": "history-loopback-only"},
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
    assert client.post(
        base + "/binding-confirm", headers=auth(actor),
        json={"previewId": preview["id"]},
    ).status_code == 201
    root = f"/api/v1/habit-anomalies/{scope.coreId}/{scope.homeId}"
    return app, client, actor, principal, resource, service, root


def _observe(client, actor, resource, root, key="habit-ha-history-key-0001"):
    return client.post(root + "/home-assistant-history", headers=auth(actor), json={
        "schemaVersion": 1, "requestKey": key,
        "sourceResourceId": resource["ref"]["id"],
    })


def test_real_history_builds_bounded_baseline_and_redacted_evidence(server, history_ha):
    _app, client, actor, _principal, resource, _service, root = _configured(
        server, history_ha
    )
    response = _observe(client, actor, resource, root)
    assert response.status_code == 201, response.text
    report = response.json()["report"]
    assert report["metric"] == "ha_state_change_count"
    assert report["classification"] in {"normal", "anomaly"}
    assert report["sampleCount"] >= 13
    assert report["current"]["source"] == "real"
    evidence = report["current"]["evidence"]
    assert evidence["provider"] == "home_assistant_history"
    assert evidence["resourceId"] == resource["ref"]["id"]
    assert evidence["derivedMetric"] == "state_change_count"
    assert "NEVER-PUBLISH" not in response.text
    assert history_ha.registry_calls == history_ha.history_calls == 1

    repeated = _observe(client, actor, resource, root, "habit-ha-history-key-0002")
    assert repeated.status_code == 201
    assert repeated.json()["report"]["sampleCount"] == report["sampleCount"]


def test_session_drift_after_registry_prevents_history_and_persistence(
    server, history_ha
):
    app, client, actor, _principal, resource, _service, root = _configured(
        server, history_ha
    )

    def revoke():
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE session_families SET revoked_at=? WHERE id=?",
                (app.state.core.settings.clock(), actor["sessionFamilyId"]),
            )

    history_ha.after_registry = revoke
    response = _observe(client, actor, resource, root, "habit-ha-drift-key-0001")
    assert response.status_code in {401, 409}
    assert history_ha.history_calls == 0
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM habit_anomaly_observations"
        ).fetchone()[0] == 0


def test_unavailable_history_is_excluded_instead_of_becoming_normal(
    server, history_ha
):
    app, client, actor, _principal, resource, _service, root = _configured(
        server, history_ha
    )
    history_ha.unavailable_history = True
    response = _observe(client, actor, resource, root, "habit-ha-unavailable-key-0001")
    assert response.status_code == 503
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM habit_anomaly_observations"
        ).fetchone()[0] == 0


def test_v1_migration_preserves_observations_feedback_and_seals(tmp_path):
    connection = sqlite3.connect(tmp_path / "habit-v1.db")
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY,value TEXT NOT NULL)")
    connection.execute(schema.V1_OBSERVATIONS)
    connection.execute(schema.TABLES["habit_anomaly_feedback"])
    for statement in schema.INDEXES.values():
        connection.execute(statement)
    connection.execute("INSERT INTO metadata VALUES('habit_anomaly_schema','1')")
    connection.execute(
        "INSERT INTO habit_anomaly_observations VALUES(?,?,?,?,?,?,?,?,?,?,?)",
        ("a" * 32, "b" * 32, "c" * 32, "request-key-00001", "series",
         "metric", "count", 1.0, 1, 2, "d" * 64),
    )
    connection.execute(
        "INSERT INTO habit_anomaly_feedback VALUES(?,?,?,?,?,?,?,?)",
        ("e" * 32, "a" * 32, "b" * 32, "c" * 32,
         "feedback-key-001", "normal", 3, "f" * 64),
    )
    schema.migrate_habit_anomalies(connection)
    row = connection.execute("SELECT * FROM habit_anomaly_observations").fetchone()
    assert (row["source"], row["evidence_json"], row["evidence_tag"]) == (
        "synthetic", None, None,
    )
    assert connection.execute(
        "SELECT COUNT(*) FROM habit_anomaly_feedback"
    ).fetchone()[0] == 1
    assert connection.execute(
        "SELECT value FROM metadata WHERE key='habit_anomaly_schema'"
    ).fetchone()[0] == "2"
    schema.migrate_habit_anomalies(connection)
    connection.close()
