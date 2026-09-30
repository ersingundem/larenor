"""F10 genuine Home Assistant history diagnostics."""

import pytest

from conftest import auth, ready
from support.f07_ha_history_fixture import ENTITY, HomeAssistantHistoryFixture


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
    root = f"/api/v1/evidence-diagnostics/{scope.coreId}/{scope.homeId}"
    return app, client, actor, resource, root


def test_real_history_diagnosis_is_redacted_limited_and_read_only(server, history_ha):
    _app, client, actor, resource, root = _configured(server, history_ha)
    response = client.post(
        root + "/home-assistant-history-diagnoses", headers=auth(actor), json={
            "schemaVersion": 1, "requestKey": "ha-diagnosis-key-0001",
            "sourceResourceId": resource["ref"]["id"],
        },
    )
    assert response.status_code == 201, response.text
    diagnosis = response.json()["diagnosis"]
    assert diagnosis["status"] == "unknown"
    assert diagnosis["certainty"] == "limited"
    assert diagnosis["readOnly"] is True and diagnosis["applied"] is False
    source = diagnosis["sources"][0]
    assert source["provenance"] == "home_assistant_history"
    assert source["evidence"]["provider"] == "home_assistant_history"
    assert source["evidence"]["resourceId"] == resource["ref"]["id"]
    assert diagnosis["unknowns"] == [{
        "code": "source_state_unknown",
        "evidenceRefs": [{
            "sourceId": "ha-resource:" + resource["ref"]["id"],
            "sourceRevision": 1,
        }],
    }]
    assert "NEVER-PUBLISH" not in response.text

    preview = client.post(
        f"{root}/diagnoses/{diagnosis['id']}/repair-previews",
        headers=auth(actor), json={
            "schemaVersion": 1, "requestKey": "ha-preview-key-00001",
            "expectedDiagnosisRevision": 1,
        },
    )
    assert preview.status_code == 201
    assert preview.json()["repairPreview"]["executionAvailable"] is False


def test_public_synthetic_healthy_claim_cannot_become_supported(server):
    app, client, _settings, clock = server
    actor = ready(server)
    scope = app.state.core.context
    root = f"/api/v1/evidence-diagnostics/{scope.coreId}/{scope.homeId}"
    response = client.post(root + "/diagnoses", headers=auth(actor), json={
        "schemaVersion": 1, "requestKey": "synthetic-claim-key-0001",
        "sources": [{
            "sourceId": "client:claim", "sourceType": "health", "revision": 1,
            "capturedAtMs": round(clock.now * 1000), "state": "healthy",
            "detail": None, "measurements": [], "events": [],
        }],
    })
    assert response.status_code == 201
    diagnosis = response.json()["diagnosis"]
    assert diagnosis["status"] == "unknown"
    assert diagnosis["certainty"] == "limited"
    assert diagnosis["sources"][0]["provenance"] == "synthetic"
    assert diagnosis["sources"][0]["evidence"] is None
    assert diagnosis["unknowns"][0]["code"] == "synthetic_source_unverified"


def test_literal_unavailable_history_is_a_limited_fault(server, history_ha):
    _app, client, actor, resource, root = _configured(server, history_ha)
    history_ha.unavailable_history = True
    response = client.post(
        root + "/home-assistant-history-diagnoses", headers=auth(actor), json={
            "schemaVersion": 1, "requestKey": "ha-unavailable-key-0001",
            "sourceResourceId": resource["ref"]["id"],
        },
    )
    assert response.status_code == 201
    diagnosis = response.json()["diagnosis"]
    assert diagnosis["status"] == "fault"
    assert diagnosis["certainty"] == "limited"
    assert diagnosis["findings"][0]["code"] == "source_unavailable"
    assert diagnosis["unknowns"][0]["code"] == "source_state_unknown"
