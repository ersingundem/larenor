from conftest import auth, login, ready
from fastapi.testclient import TestClient
from larenor_server.app import create_app


def _root(client, pair):
    context = client.get("/api/v1/context", headers=auth(pair)).json()
    return f"/api/v1/shared-expenses/{context['coreId']}/{context['homeId']}"


def test_authenticated_expense_flow_and_lost_ack_readback(server):
    _app, client, _settings, _clock = server
    pair = ready(server)
    root = _root(client, pair)
    snapshot = client.get(root, headers=auth(pair))
    assert snapshot.status_code == 200
    state = snapshot.json()
    assert state["records"] == []
    assert state["authority"]["canViewAll"] is True
    account_id = pair["user"]["id"]
    command_id = "11" * 16
    body = {
        "schemaVersion": 1,
        "commandId": command_id,
        "expectedLedgerRevision": state["ledgerRevision"],
        "expectedMembersRevision": state["authority"]["membersRevision"],
        "title": "Internet",
        "currency": "TRY",
        "totalMinor": 45000,
        "payerId": account_id,
        "participantIds": [account_id],
    }
    created = client.post(root + "/commands/create", headers=auth(pair), json=body)
    assert created.status_code == 201
    receipt = created.json()
    assert receipt["record"]["totalMinor"] == 45000
    assert receipt["ledgerRevision"] == 2

    recovered = client.get(root + f"/receipts/{command_id}", headers=auth(pair))
    assert recovered.status_code == 200
    assert recovered.json() == receipt
    replay = client.post(root + "/commands/create", headers=auth(pair), json=body)
    assert replay.status_code == 201
    assert replay.json() == receipt

    exported = client.post(
        root + "/export",
        headers=auth(pair),
        json={"schemaVersion": 1, "expectedLedgerRevision": 2},
    )
    assert exported.status_code == 200
    assert exported.json()["records"][0]["title"] == "Internet"


def test_expense_scope_revision_session_and_restart_fail_closed(server):
    _app, client, settings, _clock = server
    pair = ready(server)
    root = _root(client, pair)
    state = client.get(root, headers=auth(pair)).json()
    body = {
        "schemaVersion": 1,
        "commandId": "22" * 16,
        "expectedLedgerRevision": 1,
        "expectedMembersRevision": state["authority"]["membersRevision"] + 1,
        "title": "Electricity",
        "currency": "EUR",
        "totalMinor": 1000,
        "payerId": pair["user"]["id"],
        "participantIds": [pair["user"]["id"]],
    }
    assert (
        client.post(
            root + "/commands/create", headers=auth(pair), json=body
        ).status_code
        == 409
    )
    wrong = root.rsplit("/", 1)[0] + "/" + "f" * 32
    assert client.get(wrong, headers=auth(pair)).status_code == 404
    assert client.get(root).status_code == 401

    with TestClient(create_app(settings)) as restarted:
        fresh = login(restarted, "admin", "Synthetic new password 2026").json()
        restored = restarted.get(root, headers=auth(fresh))
        assert restored.status_code == 200
        assert restored.json()["ledgerRevision"] == 1
