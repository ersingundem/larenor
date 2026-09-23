import uuid

import pytest
from conftest import auth, ready
from fastapi.testclient import TestClient

from larenor_server.app import create_app
from larenor_server.errors import StartupError


def root(app):
    context = app.state.core.context
    return f"/api/v1/capability-evidence/{context.coreId}/{context.homeId}"


def evidence(
    *,
    evidence_id=None,
    outcome="manual_required",
    expected=0,
    request_key=None,
    dex="external_display",
):
    return {
        "schemaVersion": 1,
        "expectedRevision": expected,
        "requestKey": request_key or "evidence:" + uuid.uuid4().hex,
        "evidenceId": evidence_id or uuid.uuid4().hex,
        "capabilityId": "kiosk.window.lifecycle",
        "target": {
            "oem": "Huawei",
            "model": "MatePad 11.5 S 2026",
            "androidApi": 35,
            "webViewPackage": "com.android.webview",
            "webViewVersion": "140.0.7339.51",
            "dexProfile": dex,
            "permissions": ["android.permission.POST_NOTIFICATIONS"],
        },
        "outcome": outcome,
        "artifactName": "k14-huawei-manual-gate.json",
        "artifactSha256": "a" * 64,
        "sourceCommit": "b" * 40,
        "testCase": "manual.k14.huawei.window.lifecycle",
    }


def test_four_state_contract_exact_links_and_safe_public_shape(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    path = root(app)
    records = []
    for outcome in ["tested", "failed", "untested", "manual_required"]:
        body = evidence(outcome=outcome)
        response = client.put(
            path + "/records/" + body["evidenceId"], headers=auth(admin), json=body
        )
        assert response.status_code == 201, response.text
        record = response.json()["record"]
        assert record["outcome"] == outcome
        assert record["revision"] == 1
        assert record["artifactName"] == body["artifactName"]
        assert record["artifactSha256"] == body["artifactSha256"]
        assert record["sourceCommit"] == body["sourceCommit"]
        assert record["testCase"] == body["testCase"]
        assert "requestKey" not in record and "payloadHash" not in record
        records.append(record)

    listing = client.get(path + "/records?limit=10", headers=auth(admin))
    assert listing.status_code == 200
    payload = listing.json()
    assert payload["scope"] == app.state.core.context.model_dump()
    assert len(payload["records"]) == 4
    assert payload["records"] == sorted(payload["records"], key=lambda row: row["id"])
    assert payload["nextAfter"] is None

    for changes in [
        {"outcome": "passed"},
        {"artifactName": "/tmp/private/report.json"},
        {"artifactName": "https:evil.invalid"},
        {"sourceCommit": "B" * 40},
        {"testCase": "../../secret"},
        {"token": "must-not-enter-contract"},
    ]:
        body = evidence()
        body.update(changes)
        rejected = client.put(
            path + "/records/" + body["evidenceId"], headers=auth(admin), json=body
        )
        assert rejected.status_code == 400


def test_exact_replay_stale_revision_scope_and_restart_fail_closed(server):
    app, client, settings, _clock = server
    admin = ready(server)
    path = root(app)
    body = evidence(request_key="evidence:fixed-request-0001")
    url = path + "/records/" + body["evidenceId"]
    first = client.put(url, headers=auth(admin), json=body)
    replay = client.put(url, headers=auth(admin), json=body)
    assert first.status_code == 201 and replay.json() == first.json()

    changed_replay = client.put(
        url, headers=auth(admin), json={**body, "outcome": "tested"}
    )
    assert changed_replay.status_code == 409
    assert changed_replay.json()["error"]["code"] == "capability_evidence_replay"

    stale = evidence(
        evidence_id=body["evidenceId"],
        outcome="tested",
        expected=0,
        request_key="evidence:new-request-0002",
    )
    stale_response = client.put(url, headers=auth(admin), json=stale)
    assert stale_response.status_code == 409
    assert stale_response.json()["error"]["code"] == "capability_evidence_changed"

    updated = {**stale, "expectedRevision": 1}
    accepted = client.put(url, headers=auth(admin), json=updated)
    assert accepted.status_code == 200
    assert accepted.json()["record"]["revision"] == 2
    assert accepted.json()["record"]["outcome"] == "tested"

    wrong_home = path.replace(app.state.core.context.homeId, "f" * 32)
    assert client.get(wrong_home + "/records", headers=auth(admin)).status_code == 404

    with TestClient(create_app(settings)) as restarted:
        retained = restarted.get(path + "/records", headers=auth(admin))
        assert retained.status_code == 200
        assert retained.json()["records"][0]["revision"] == 2
        assert retained.json()["records"][0]["outcome"] == "tested"


def test_only_admin_can_publish_evidence(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    body = evidence()
    # A bearer token without a ready administrator remains fail-closed.
    anonymous = client.put(root(app) + "/records/" + body["evidenceId"], json=body)
    assert anonymous.status_code == 401
    assert client.get(root(app) + "/records", headers=auth(admin)).status_code == 200


@pytest.mark.parametrize(
    "change",
    [
        "UPDATE capability_evidence SET tag='wrong'",
        "CREATE INDEX unrelated_evidence_index ON capability_evidence(actor_id)",
        (
            "CREATE TRIGGER unrelated_evidence_trigger BEFORE INSERT ON "
            "capability_evidence BEGIN SELECT RAISE(IGNORE); END"
        ),
    ],
)
def test_integrity_and_attached_schema_tampering_fail_restart_without_changes(
    server, change
):
    app, client, settings, _clock = server
    admin = ready(server)
    body = evidence()
    response = client.put(
        root(app) + "/records/" + body["evidenceId"],
        headers=auth(admin),
        json=body,
    )
    assert response.status_code == 201
    with app.state.core.db.transaction() as connection:
        connection.execute(change)
    with app.state.core.db.connection() as connection:
        before = "\n".join(connection.iterdump())
    with pytest.raises(StartupError, match="^capability_evidence_storage_invalid$"):
        create_app(settings)
    with app.state.core.db.connection() as connection:
        assert "\n".join(connection.iterdump()) == before
