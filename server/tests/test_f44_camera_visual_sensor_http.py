import sqlite3

import pytest
from conftest import auth, ready
from fastapi.testclient import TestClient
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from test_f44_camera_visual_sensors import rule


def _rule(app, revision=1):
    return rule(revision=revision).model_copy(update={"cameraId": "5" * 32}).model_dump(
        mode="json"
    ) | {
        "ruleRevision": revision,
    }


def test_admin_configures_persistent_unknown_summary_with_explicit_capability(server):
    app, client, settings, _clock = server
    pair = ready(server)
    context = app.state.core.context
    root = f"/api/v1/camera-visual-sensors/{context.coreId}/{context.homeId}"
    value = _rule(app)
    rule_id = value["ruleId"]

    assert client.get(root + "/summary").status_code == 401
    configured = client.put(
        root + f"/rules/{rule_id}",
        headers=auth(pair),
        json={"schemaVersion": 1, "expectedRevision": 0, "rule": value},
    )
    assert configured.status_code == 200
    sensor = configured.json()["rule"]
    assert sensor["state"] == "unknown"
    assert sensor["status"] == "unavailable"
    assert sensor["automationEligible"] is False
    assert sensor["accessControlEligible"] is False

    response = client.get(root + "/summary", headers=auth(pair))
    assert response.status_code == 200
    body = response.json()
    assert body["rules"] == [sensor]
    capability = body["capability"]
    assert set(capability) == {
        "schemaVersion",
        "architecture",
        "avx",
        "avx2",
        "arm64",
        "detectorState",
        "trainingSupported",
        "inferenceSupported",
        "reason",
    }
    assert capability["detectorState"] == "unavailable"
    assert capability["trainingSupported"] is False
    assert capability["inferenceSupported"] is False
    assert capability["architecture"] in {"amd64", "arm64", "other"}
    if capability["architecture"] == "arm64":
        assert capability["arm64"] is True
        assert capability["avx"] == capability["avx2"] == "not_applicable"

    stale = client.put(
        root + f"/rules/{rule_id}",
        headers=auth(pair),
        json={"schemaVersion": 1, "expectedRevision": 0, "rule": value},
    )
    assert stale.status_code == 409
    with TestClient(create_app(settings)) as restarted:
        assert restarted.get(root + "/summary", headers=auth(pair)).json()["rules"] == [
            sensor
        ]


def test_scope_shape_and_storage_tamper_fail_closed(server):
    app, client, settings, _clock = server
    pair = ready(server)
    context = app.state.core.context
    root = f"/api/v1/camera-visual-sensors/{context.coreId}/{context.homeId}"
    value = _rule(app)
    rule_id = value["ruleId"]
    assert (
        client.put(
            root + f"/rules/{rule_id}",
            headers=auth(pair),
            json={"schemaVersion": 1, "expectedRevision": 0, "rule": value},
        ).status_code
        == 200
    )
    assert (
        client.get(
            f"/api/v1/camera-visual-sensors/{'0' * 32}/{context.homeId}/summary",
            headers=auth(pair),
        ).status_code
        == 404
    )

    with sqlite3.connect(settings.database_file) as connection:
        connection.execute(
            "UPDATE camera_visual_sensor_rules SET rule_json='{}' WHERE id=?",
            (rule_id,),
        )
    overwritten = client.put(
        root + f"/rules/{rule_id}",
        headers=auth(pair),
        json={"schemaVersion": 1, "expectedRevision": 1, "rule": _rule(app, 2)},
    )
    assert overwritten.status_code == 503
    assert overwritten.json()["error"]["code"] == "visual_sensor_storage_unavailable"
    with pytest.raises(StartupError, match="camera_visual_sensor_storage_invalid"):
        create_app(settings)
