"""F08-F11 acceptance at the production FastAPI/Core boundary."""

import json

from conftest import auth, ready
from test_admin import activate, create as create_user


def _root(app, feature):
    scope = app.state.core.context
    return f"/api/v1/{feature}/{scope.coreId}/{scope.homeId}"


def test_f08_real_measurement_media_pressure_priority_and_cancellation(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    root = _root(app, "ai-resources")

    policy = client.put(root + "/policy", headers=auth(admin), json={
        "schemaVersion": 1, "expectedRevision": 1, "maxMemoryMb": 64,
        "maxCpuPercent": 70, "maxConcurrentJobs": 2, "mediaCpuPercent": 25,
    })
    assert policy.status_code == 200, policy.text
    capacity = policy.json()["capacity"]
    assert capacity["memoryMb"] >= 64 and capacity["cpuCount"] >= 1
    assert 0 <= capacity["processMemoryMb"] <= capacity["memoryMb"]
    assert 0 <= capacity["systemLoadPercent"] <= 100

    create_user(client, admin)
    member = activate(client, "member")
    body = {
        "schemaVersion": 1, "expectedPolicyRevision": 2,
        "requestKey": "ai-job-media-pressure-0001", "kind": "assistant",
        "label": "Bounded assistant", "priority": 100,
        "memoryMb": 64, "cpuPercent": 30,
    }
    first = client.post(root + "/jobs", headers=auth(member), json=body)
    assert first.status_code == 200, first.text
    job = first.json()["jobs"][0]
    assert job["state"] == "running" and job["ownedByCurrentSession"] is True
    assert client.post(root + "/jobs", headers=auth(member), json=body).json()["jobs"][0]["id"] == job["id"]
    conflict = client.post(root + "/jobs", headers=auth(member), json={**body, "label": "Changed"})
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "ai_resource_replay_changed"

    pressured = client.put(root + "/media-activity", headers=auth(member), json={
        "schemaVersion": 1, "active": True, "leaseSeconds": 90,
    })
    assert pressured.status_code == 200
    pressured_job = pressured.json()["jobs"][0]
    assert pressured.json()["capacity"]["mediaActive"] is True
    assert pressured.json()["capacity"]["effectiveCpuPercent"] == 25
    assert pressured_job["state"] == "blocked" and pressured_job["reason"] == "mediaActive"

    cancelled = client.post(
        f"{root}/jobs/{job['id']}/cancel", headers=auth(member),
        json={"schemaVersion": 1, "expectedRevision": 1},
    )
    assert cancelled.status_code == 200
    assert cancelled.json()["jobs"][0]["state"] == "cancelled"
    too_large = client.post(root + "/jobs", headers=auth(member), json={
        **body, "requestKey": "ai-job-hardware-limit-0002", "memoryMb": 128,
    })
    assert too_large.status_code == 200
    blocked = next(item for item in too_large.json()["jobs"] if item["memoryMb"] == 128)
    assert blocked["state"] == "blocked" and blocked["reason"] == "insufficientHardware"


def test_f09_visible_ttl_correction_forget_isolation_and_restore_tombstone(server):
    app, client, _settings, clock = server
    admin = ready(server)
    root = _root(app, "ai-memory")
    remember = {
        "schemaVersion": 1, "requestKey": "memory-create-key-0001",
        "source": {"schemaVersion": 1, "kind": "manual", "description": "User preference"},
        "content": "Kitchen light prefers warm white", "durationSeconds": 3600,
    }
    created = client.post(root + "/memories", headers=auth(admin), json=remember)
    assert created.status_code == 201, created.text
    memory = created.json()["memory"]
    assert memory["source"]["description"] == "User preference"
    assert memory["learnedBy"] == "admin"
    assert memory["retention"]["durationSeconds"] == 3600
    old_backup = client.get(root + "/backup", headers=auth(admin)).json()

    corrected = client.put(f"{root}/memories/{memory['memoryId']}", headers=auth(admin), json={
        **remember, "requestKey": "memory-correct-key-0002", "expectedRevision": 1,
        "content": "Kitchen light prefers neutral white",
    })
    assert corrected.status_code == 200
    current = corrected.json()["memory"]
    search = client.post(root + "/search", headers=auth(admin), json={
        "schemaVersion": 1, "query": "neutral", "limit": 20,
    })
    assert [item["memoryId"] for item in search.json()["memories"]] == [memory["memoryId"]]

    forgotten = client.post(f"{root}/memories/{memory['memoryId']}/forget", headers=auth(admin), json={
        "schemaVersion": 1, "requestKey": "memory-forget-key-0003",
        "expectedRevision": current["revision"], "reason": "userRequested",
    })
    assert forgotten.status_code == 200
    restore = client.post(root + "/backup/restore", headers=auth(admin), json={
        "schemaVersion": 1, "requestKey": "memory-restore-key-0004",
        "records": old_backup["records"], "tombstones": old_backup["tombstones"],
    })
    assert restore.status_code == 200
    assert restore.json() == {"schemaVersion": 1, "restoredCount": 0, "blockedCount": 1}
    assert client.get(root, headers=auth(admin)).json()["memories"] == []
    assert client.post(root + "/search", headers=auth(admin), json={
        "schemaVersion": 1, "query": "kitchen", "limit": 20,
    }).json()["memories"] == []

    create_user(client, admin)
    member = activate(client, "member")
    assert client.get(root, headers=auth(member)).json()["memories"] == []
    clock.now += 1


def test_f10_evidence_links_redaction_unknowns_and_preview_never_execute(server):
    app, client, _settings, clock = server
    admin = ready(server)
    root = _root(app, "evidence-diagnostics")
    now_ms = round(clock.now * 1000)
    body = {
        "schemaVersion": 1, "requestKey": "diagnosis-create-key-0001",
        "sources": [
            {
                "sourceId": "service:ha", "sourceType": "measurement", "revision": 3,
                "capturedAtMs": now_ms, "state": "degraded",
                "detail": "token=SECRET_MUST_NOT_SURVIVE",
                "measurements": [{"measurementId": "latency", "metric": "latency_ms", "value": 900,
                    "unit": "milliseconds", "comparator": "above", "threshold": 500}],
                "events": [],
            },
            {
                "sourceId": "service:unknown", "sourceType": "health", "revision": 1,
                "capturedAtMs": now_ms, "state": "unknown", "detail": "password=PRIVATE",
                "measurements": [], "events": [],
            },
        ],
    }
    response = client.post(root + "/diagnoses", headers=auth(admin), json=body)
    assert response.status_code == 201, response.text
    diagnosis = response.json()["diagnosis"]
    encoded = json.dumps(response.json())
    assert "SECRET_MUST_NOT_SURVIVE" not in encoded and "PRIVATE" not in encoded
    assert diagnosis["status"] == "fault" and diagnosis["certainty"] == "limited"
    assert diagnosis["readOnly"] is True and diagnosis["applied"] is False
    assert all(item["evidenceRefs"] for item in diagnosis["findings"])
    assert diagnosis["unknowns"][0]["code"] == "source_state_unknown"
    assert len(diagnosis["redactions"]) == 2

    replay = client.post(root + "/diagnoses", headers=auth(admin), json=body)
    assert replay.json() == response.json()
    preview = client.post(
        f"{root}/diagnoses/{diagnosis['id']}/repair-previews",
        headers=auth(admin), json={"schemaVersion": 1,
            "requestKey": "diagnosis-preview-key-0002", "expectedDiagnosisRevision": 1},
    )
    assert preview.status_code == 201
    repair = preview.json()["repairPreview"]
    assert repair["previewOnly"] is True and repair["executionAvailable"] is False
    assert repair["applied"] is False

    stale = client.post(root + "/diagnoses", headers=auth(admin), json={
        **body, "requestKey": "diagnosis-stale-key-0003",
        "sources": [{**body["sources"][0], "capturedAtMs": now_ms - 301000}],
    })
    assert stale.status_code == 409
    assert stale.json()["error"]["code"] == "diagnostic_source_stale"


def test_f11_catalog_enforces_capabilities_limits_scope_and_stop(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    root = _root(app, "mini-plugins")
    catalog = client.get(root + "/catalog", headers=auth(admin))
    assert catalog.status_code == 200
    template = catalog.json()["templates"][0]
    assert template["capabilities"] == ["home.resource_count.read"]
    assert template["limits"]["network"] == {"mode": "deny_all", "allowedDestinations": []}
    assert template["limits"]["filesystem"]["hostPathsAvailable"] is False
    assert template["denials"] == {
        "crossHomeAccess": False, "secretsAvailable": False,
        "hostManagementAvailable": False, "arbitraryCodeAvailable": False,
    }

    create = {"schemaVersion": 1, "requestKey": "mini-plugin-create-0001",
              "templateId": "home-resource-count", "displayName": "Resource count"}
    created = client.post(root, headers=auth(admin), json=create)
    assert created.status_code == 201, created.text
    instance = created.json()["instance"]
    assert client.post(root, headers=auth(admin), json=create).json() == created.json()
    render = client.post(f"{root}/{instance['id']}/render", headers=auth(admin), json={
        "schemaVersion": 1, "expectedRevision": 1,
    })
    assert render.status_code == 200
    result = render.json()["result"]
    assert result["networkRequests"] == result["filesystemBytes"] == 0
    assert result["secretReads"] == result["hostOperations"] == 0
    assert result["outputBytesMaximum"] == 1024

    stopped = client.post(f"{root}/{instance['id']}/stop", headers=auth(admin), json={
        "schemaVersion": 1, "requestKey": "mini-plugin-stop-key-0002", "expectedRevision": 1,
    })
    assert stopped.status_code == 200 and stopped.json()["instance"]["state"] == "stopped"
    rejected = client.post(f"{root}/{instance['id']}/render", headers=auth(admin), json={
        "schemaVersion": 1, "expectedRevision": 2,
    })
    assert rejected.status_code == 409
    assert rejected.json()["error"]["code"] == "mini_plugin_stopped"

    create_user(client, admin)
    member = activate(client, "member")
    assert client.get(root + "/catalog", headers=auth(member)).status_code == 403
    wrong = root.rsplit("/", 1)[0] + "/" + "f" * 32
    assert client.get(wrong, headers=auth(admin)).status_code == 404
