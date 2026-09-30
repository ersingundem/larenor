"""F07 acceptance at the production FastAPI habit-anomaly boundary."""

from conftest import auth, ready
from test_admin import activate, create as create_user


def _root(app):
    scope = app.state.core.context
    return f"/api/v1/habit-anomalies/{scope.coreId}/{scope.homeId}"


def _observation(index, observed_at_ms, value=10):
    return {
        "schemaVersion": 1,
        "requestKey": f"habit-sample-{index:04d}",
        "seriesId": "service_unavailable_count",
        "metric": "service_unavailable_count",
        "unit": "count",
        "value": value,
        "observedAtMs": observed_at_ms,
    }


def test_robust_baseline_anomaly_feedback_and_staleness_are_explicit(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    root = _root(app)
    clock = server[3]

    reports = []
    for index in range(13):
        clock.now += 60
        value = 100 if index == 12 else 10
        response = client.post(
            root + "/observations",
            headers=auth(admin),
            json=_observation(index, round(clock.now * 1000), value),
        )
        assert response.status_code == 201, response.text
        reports.append(response.json()["report"])

    assert reports[0]["classification"] == "unknown"
    assert reports[0]["unknownReason"] == "insufficient_samples"
    report = reports[-1]
    assert report["modelVersion"] == "robust-mad-v1"
    assert report["classification"] == "anomaly"
    assert report["unknownReason"] is None
    assert report["baseline"] == {
        "sampleCount": 12,
        "center": 10.0,
        "tolerance": 1.0,
    }
    assert report["missingDataIsUnknown"] is True

    current_id = report["current"]["observationId"]
    feedback = {
        "schemaVersion": 1,
        "requestKey": "habit-feedback-key-0001",
        "expectedObservationId": current_id,
        "label": "false_positive",
    }
    marked = client.post(
        f"{root}/observations/{current_id}/feedback",
        headers=auth(admin),
        json=feedback,
    )
    assert marked.status_code == 200, marked.text
    assert marked.json()["report"]["current"]["feedback"] == "false_positive"
    assert client.post(
        f"{root}/observations/{current_id}/feedback",
        headers=auth(admin),
        json=feedback,
    ).json() == marked.json()

    changed = client.post(
        f"{root}/observations/{current_id}/feedback",
        headers=auth(admin),
        json={**feedback, "label": "normal"},
    )
    assert changed.status_code == 409
    assert changed.json()["error"]["code"] == "idempotency_conflict"

    clock.now += 301
    refreshed = client.post(
        "/api/v1/auth/refresh", json={"refreshToken": admin["refreshToken"]}
    ).json()
    stale = client.get(root, headers=auth(refreshed))
    assert stale.status_code == 200
    assert stale.json()["reports"][0]["classification"] == "unknown"
    assert stale.json()["reports"][0]["unknownReason"] == "stale_data"


def test_observations_are_idempotent_and_account_isolated(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    root = _root(app)
    clock = server[3]
    body = _observation(1, round(clock.now * 1000))

    first = client.post(root + "/observations", headers=auth(admin), json=body)
    assert first.status_code == 201
    assert client.post(
        root + "/observations", headers=auth(admin), json=body
    ).json() == first.json()
    conflict = client.post(
        root + "/observations",
        headers=auth(admin),
        json={**body, "value": 11},
    )
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "idempotency_conflict"

    create_user(client, admin)
    member = activate(client, "member")
    isolated = client.get(root, headers=auth(member))
    assert isolated.status_code == 200
    assert isolated.json()["reports"] == []
