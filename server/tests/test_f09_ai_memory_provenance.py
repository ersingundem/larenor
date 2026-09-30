"""F09 public writes cannot mint trusted AI or integration provenance."""

import copy
import uuid

import pytest

from conftest import auth, ready


def _root(app):
    scope = app.state.core.context
    return f"/api/v1/ai-memory/{scope.coreId}/{scope.homeId}"


def _remember(kind="manual", *, request_key="memory-provenance-create-0001"):
    return {
        "schemaVersion": 1,
        "requestKey": request_key,
        "source": {
            "schemaVersion": 1,
            "kind": kind,
            "description": "Visible source label",
        },
        "content": "Kitchen light prefers warm white",
        "durationSeconds": 3600,
    }


@pytest.mark.parametrize("kind", ["assistant", "automation", "integration"])
def test_public_remember_and_correct_cannot_claim_trusted_source(server, kind):
    app, client, _settings, _clock = server
    actor = ready(server)
    root = _root(app)
    forged = client.post(root + "/memories", headers=auth(actor), json=_remember(kind))
    assert forged.status_code == 400
    assert client.get(root, headers=auth(actor)).json()["memories"] == []

    created = client.post(root + "/memories", headers=auth(actor), json=_remember())
    assert created.status_code == 201, created.text
    memory = created.json()["memory"]
    changed = client.put(
        f"{root}/memories/{memory['memoryId']}",
        headers=auth(actor),
        json={
            **_remember(kind, request_key="memory-provenance-correct-0002"),
            "expectedRevision": memory["revision"],
        },
    )
    assert changed.status_code == 400
    current = client.get(root, headers=auth(actor)).json()["memories"]
    assert len(current) == 1
    assert current[0]["revision"] == 1
    assert current[0]["source"]["kind"] == "manual"
    assert current[0]["learnedBy"] == "admin"


@pytest.mark.parametrize("forgery", ["source", "learned_by"])
def test_restore_rejects_forged_provenance_before_tombstone_side_effects(
    server, forgery
):
    app, client, _settings, _clock = server
    actor = ready(server)
    root = _root(app)
    created = client.post(root + "/memories", headers=auth(actor), json=_remember())
    assert created.status_code == 201, created.text
    memory = created.json()["memory"]
    record = copy.deepcopy(client.get(root + "/backup", headers=auth(actor)).json()["records"][0])
    record["memoryId"] = uuid.uuid4().hex
    if forgery == "source":
        record["source"] = {
            "schemaVersion": 1,
            "kind": "assistant",
            "description": "Claimed assistant receipt",
        }
    else:
        record["learnedBy"] = "another-account"
    response = client.post(
        root + "/backup/restore",
        headers=auth(actor),
        json={
            "schemaVersion": 1,
            "requestKey": "memory-provenance-restore-0003-" + forgery,
            "records": [record],
            "tombstones": [
                {
                    "schemaVersion": 1,
                    "memoryId": memory["memoryId"],
                    "deletedRevision": memory["revision"] + 1,
                    "deletedAt": record["updatedAt"],
                    "reason": "userRequested",
                }
            ],
        },
    )
    assert response.status_code == 400, response.text
    current = client.get(root, headers=auth(actor)).json()["memories"]
    assert [value["memoryId"] for value in current] == [memory["memoryId"]]
    assert current[0]["source"]["kind"] == "manual"
    assert current[0]["learnedBy"] == "admin"


def test_valid_manual_restore_binds_learned_by_to_current_actor(server):
    app, client, _settings, _clock = server
    actor = ready(server)
    root = _root(app)
    created = client.post(root + "/memories", headers=auth(actor), json=_remember())
    record = client.get(root + "/backup", headers=auth(actor)).json()["records"][0]
    record["memoryId"] = uuid.uuid4().hex
    response = client.post(
        root + "/backup/restore",
        headers=auth(actor),
        json={
            "schemaVersion": 1,
            "requestKey": "memory-provenance-restore-valid-0004",
            "records": [record],
            "tombstones": [],
        },
    )
    assert response.status_code == 200, response.text
    assert response.json()["restoredCount"] == 1
    restored = next(
        value
        for value in client.get(root, headers=auth(actor)).json()["memories"]
        if value["memoryId"] == record["memoryId"]
    )
    assert restored["source"]["kind"] == "manual"
    assert restored["learnedBy"] == "admin"
