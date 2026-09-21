import json

from conftest import auth, ready


def _scope(app):
    return app.state.core.context.coreId, app.state.core.context.homeId


def _account_revision(app, account_id):
    with app.state.core.db.connection() as connection:
        return connection.execute(
            "SELECT revision FROM users WHERE id=?", (account_id,)
        ).fetchone()[0]


def _host(client, headers, root):
    response = client.post(root + "/hosts", headers=headers, json={
        "schemaVersion": 1,
        "registrationId": "1" * 32,
        "name": "Synthetic Sunshine host",
        "pairingRevision": 3,
        "credentialHandle": "2" * 32,
        "codecs": ["h264", "hevc"],
        "maxWidth": 3840,
        "maxHeight": 2160,
        "maxFps": 120,
    })
    assert response.status_code == 201, response.text
    return response.json()


def _session(client, headers, root, host, account_revision, **changes):
    body = {
        "schemaVersion": 1,
        "requestKey": "session-request-0001",
        "expectedHostRevision": host["revision"],
        "expectedPairingRevision": host["pairingRevision"],
        "accountRevision": account_revision,
        "routeRevision": 4,
        "lifecycleRevision": 5,
        "displayRevision": 6,
        "networkRevision": 7,
        "policyRevision": 8,
        "expiresAt": 1788610200.0,
        **changes,
    }
    return client.post(
        root + f"/hosts/{host['ref']['id']}/sessions", headers=headers, json=body
    )


def test_host_registry_is_secret_free_revision_bound_and_tamper_evident(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    headers = auth(pair)
    core_id, home_id = _scope(app)
    root = f"/api/v1/game-streaming/{core_id}/{home_id}"
    host = _host(client, headers, root)

    assert set(host) == {
        "schemaVersion", "ref", "revision", "name", "pairingRevision", "active",
        "codecs", "maxWidth", "maxHeight", "maxFps",
    }
    assert "credential" not in json.dumps(host).lower()
    page = client.get(root + "/hosts", headers=headers).json()
    assert page["hosts"] == [host]
    assert page["accountRevision"] == _account_revision(app, pair["user"]["id"])

    with app.state.core.db.transaction() as connection:
        connection.execute("UPDATE game_stream_hosts SET name='tampered'")
    response = client.get(root + "/hosts", headers=headers)
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "server_unavailable"


def test_session_exact_authority_survives_restart_boundary_and_rejects_other_login(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    headers = auth(pair)
    account_id = pair["user"]["id"]
    revision = _account_revision(app, account_id)
    core_id, home_id = _scope(app)
    root = f"/api/v1/game-streaming/{core_id}/{home_id}"
    host = _host(client, headers, root)

    stale = _session(client, headers, root, host, revision, expectedHostRevision=2)
    assert stale.status_code == 409
    opened = _session(client, headers, root, host, revision)
    assert opened.status_code == 201, opened.text
    session = opened.json()
    assert session["authority"] == {
        "accountRevision": revision,
        "displayRevision": 6,
        "expectedHostRevision": 1,
        "expectedPairingRevision": 3,
        "lifecycleRevision": 5,
        "networkRevision": 7,
        "policyRevision": 8,
        "routeRevision": 4,
    }
    # Same bytes recover the durable receipt; changed bytes never reuse the lease.
    assert _session(client, headers, root, host, revision).json() == session
    conflict = _session(client, headers, root, host, revision, routeRevision=9)
    assert conflict.status_code == 409

    second = client.post("/api/v1/auth/login", json={
        "username": "admin", "password": "Synthetic new password 2026",
        "deviceName": "Other session",
    }).json()
    denied = client.post(
        root + f"/sessions/{session['id']}/commands", headers=auth(second), json={
            "schemaVersion": 1, "requestKey": "intent-request-0001",
            "expectedSessionRevision": 1, "intent": "stream",
        })
    assert denied.status_code == 404


def test_intent_receipt_is_bounded_exact_and_lost_ack_never_replays(server):
    app, client, _settings, clock = server
    pair = ready(server)
    headers = auth(pair)
    revision = _account_revision(app, pair["user"]["id"])
    core_id, home_id = _scope(app)
    root = f"/api/v1/game-streaming/{core_id}/{home_id}"
    host = _host(client, headers, root)
    session = _session(client, headers, root, host, revision).json()
    command_url = root + f"/sessions/{session['id']}/commands"
    intent = {"schemaVersion": 1, "requestKey": "intent-request-0001",
              "expectedSessionRevision": 1, "intent": "stream"}

    first = client.post(command_url, headers=headers, json=intent)
    assert first.status_code == 201, first.text
    command = first.json()
    assert command["state"] == "authorized"
    assert client.post(command_url, headers=headers, json=intent).json() == command
    conflict = client.post(command_url, headers=headers, json={**intent, "intent": "stop"})
    assert conflict.status_code == 409

    complete_url = command_url + f"/{command['id']}/complete"
    verified = {"schemaVersion": 1, "expectedSessionRevision": 1,
                "state": "verified", "result": "streaming", "readbackRevision": 11}
    receipt = client.post(complete_url, headers=headers, json=verified)
    assert receipt.status_code == 200, receipt.text
    assert receipt.json()["state"] == "verified"
    assert client.post(complete_url, headers=headers, json=verified).json() == receipt.json()
    changed = client.post(complete_url, headers=headers, json={
        **verified, "readbackRevision": 12})
    assert changed.status_code == 409

    clock.now = session["expiresAt"]
    late = client.post(command_url, headers=headers, json={
        **intent, "requestKey": "intent-request-0002"})
    assert late.status_code == 409
