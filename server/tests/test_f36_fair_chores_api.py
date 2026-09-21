from conftest import auth, login, ready
from fastapi.testclient import TestClient
from larenor_server.app import create_app


def _root(client, pair):
    context = client.get("/api/v1/context", headers=auth(pair)).json()
    return f"/api/v1/fair-chores/{context['coreId']}/{context['homeId']}"


def test_authenticated_chore_flow_and_lost_ack_receipt(server):
    _app, client, _settings, clock = server
    pair = ready(server)
    root = _root(client, pair)
    created = client.post(
        root,
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "commandId": "10" * 16,
            "title": "Clean kitchen",
            "timezone": "Europe/Istanbul",
            "intervalDays": 7,
            "dueAt": clock.now + 3600,
        },
    )
    assert created.status_code == 201
    task = created.json()["task"]

    page = client.get(root, headers=auth(pair))
    assert page.status_code == 200
    assert page.json()["tasks"] == [task]
    assert page.json()["authority"]["accountId"] == pair["user"]["id"]

    command = "20" * 16
    completed = client.post(
        f"{root}/{task['id']}/commands/complete",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "commandId": command,
            "expectedRevision": task["revision"],
            "completedAt": clock.now + 120,
        },
    )
    assert completed.status_code == 200
    receipt = completed.json()
    assert receipt["commandId"] == command
    assert receipt["task"]["revision"] == 2

    recovered = client.get(f"{root}/receipts/{command}", headers=auth(pair))
    assert recovered.status_code == 200
    assert recovered.json() == receipt

    replay = client.post(
        f"{root}/{task['id']}/commands/complete",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "commandId": command,
            "expectedRevision": task["revision"],
            "completedAt": clock.now + 120,
        },
    )
    assert replay.status_code == 200
    assert replay.json() == receipt


def test_chore_scope_session_and_restart_are_fail_closed(server):
    _app, client, settings, clock = server
    pair = ready(server)
    root = _root(client, pair)
    created = client.post(
        root,
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "commandId": "30" * 16,
            "title": "Water plants",
            "timezone": "Europe/Istanbul",
            "intervalDays": 2,
            "dueAt": clock.now + 3600,
        },
    ).json()
    wrong = root.rsplit("/", 1)[0] + "/" + "f" * 32
    assert client.get(wrong, headers=auth(pair)).status_code == 404
    assert client.get(root).status_code == 401

    with TestClient(create_app(settings)) as restarted:
        fresh = login(restarted, "admin", "Synthetic new password 2026").json()
        page = restarted.get(root, headers=auth(fresh))
        assert page.status_code == 200
        assert page.json()["tasks"][0]["id"] == created["task"]["id"]
