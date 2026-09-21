import uuid

from conftest import auth, ready


def roots(app):
    context = app.state.core.context
    scope = f"{context.coreId}/{context.homeId}"
    return f"/api/v1/tablet-fleet/{scope}", f"/api/v1/admin/paired-remote/{scope}"


def register(client, pair, fleet):
    response = client.post(fleet + "/devices", headers=auth(pair), json={
        "schemaVersion": 1,
        "registrationId": uuid.uuid4().hex,
        "name": "Kitchen tablet",
        "platform": "android",
        "managementMode": "standard",
        "clientVersion": "1.0.0",
        "appliedProfileRevision": 1,
    })
    assert response.status_code == 201, response.text
    return response.json()["tablet"]


def create_pairing(server, scopes=("read", "control")):
    app, client, _settings, clock = server
    pair = ready(server)
    fleet, remote = roots(app)
    tablet = register(client, pair, fleet)
    response = client.post(remote + "/pairings", headers=auth(pair), json={
        "schemaVersion": 1,
        "requestId": uuid.uuid4().hex,
        "deviceId": tablet["ref"]["id"],
        "expectedDeviceRevision": tablet["revision"],
        "name": "Home Assistant bridge",
        "scopes": list(scopes),
        "expiresAt": clock.now + 3600.0,
    })
    assert response.status_code == 201, response.text
    return pair, remote, response.json(), tablet


def paired_headers(token):
    return {"X-Larenor-Pairing-Token": token}


def test_pairing_identity_scope_revoke_and_secret_free_inventory(server):
    pair, remote, created, tablet = create_pairing(server, ("read",))
    pairing, token = created["pairing"], created["token"]
    assert len(token) == 43
    assert pairing["deviceId"] == tablet["ref"]["id"]
    listed = server[1].get(remote + "/pairings", headers=auth(pair))
    assert listed.status_code == 200
    assert token not in listed.text
    assert "token" not in str(listed.json()).lower()

    discovery = server[1].get(
        remote + f"/pairings/{pairing['id']}/mqtt/discovery",
        headers=paired_headers(token),
    )
    assert discovery.status_code == 200, discovery.text
    assert discovery.json()["listenerEnabled"] is False
    assert discovery.json()["commandRetainAllowed"] is False
    assert len(discovery.json()["sensors"]) == 4
    assert token not in discovery.text
    assert server[1].get(
        remote + f"/pairings/{pairing['id']}/mqtt/discovery?token={token}"
    ).status_code == 401

    forbidden = server[1].post(
        remote + f"/pairings/{pairing['id']}/mqtt/commands",
        headers=paired_headers(token),
        json=command(sequence=1),
    )
    assert forbidden.status_code == 403
    revoked = server[1].delete(
        remote + f"/pairings/{pairing['id']}",
        headers=auth(pair),
        params={"expectedRevision": pairing["revision"]},
    )
    assert revoked.status_code == 204
    assert server[1].get(
        remote + f"/pairings/{pairing['id']}/mqtt/discovery",
        headers=paired_headers(token),
    ).status_code == 401


def command(*, request_id=None, sequence=1, retained=False):
    return {
        "schemaVersion": 1,
        "requestId": request_id or uuid.uuid4().hex,
        "sequence": sequence,
        "kind": "refreshDashboard",
        "retained": retained,
        "expiresAt": 1788610000.0,
    }


def test_mqtt_command_replay_retained_and_ack_are_fail_closed(server):
    pair, remote, created, _tablet = create_pairing(server)
    pairing, token = created["pairing"], created["token"]
    endpoint = remote + f"/pairings/{pairing['id']}/mqtt/commands"
    body = command(request_id="a" * 32, sequence=1)
    first = server[1].post(endpoint, headers=paired_headers(token), json=body)
    replay = server[1].post(endpoint, headers=paired_headers(token), json=body)
    assert first.status_code == 201, first.text
    assert first.json()["ack"]["state"] == "accepted"
    assert replay.status_code == 200
    assert replay.json()["ack"]["replayed"] is True

    retained = server[1].post(
        endpoint, headers=paired_headers(token), json=command(sequence=2, retained=True)
    )
    assert retained.status_code == 409
    assert retained.json()["error"]["code"] == "mqtt_retained_command_denied"
    older = server[1].post(
        endpoint, headers=paired_headers(token), json=command(sequence=1)
    )
    assert older.status_code == 409
    assert older.json()["error"]["code"] == "mqtt_command_replay"

    command_id = first.json()["ack"]["commandId"]
    ack_path = endpoint + f"/{command_id}/ack"
    ack_body = {"schemaVersion": 1, "sequence": 1, "result": "succeeded"}
    completed = server[1].post(ack_path, headers=paired_headers(token), json=ack_body)
    duplicate = server[1].post(ack_path, headers=paired_headers(token), json=ack_body)
    assert completed.status_code == 200
    assert completed.json()["ack"]["state"] == "completed"
    assert duplicate.json()["ack"]["replayed"] is True
    assert server[1].post(
        ack_path,
        headers=paired_headers(token),
        json={**ack_body, "result": "failed"},
    ).status_code == 409

    with server[0].state.core.db.connection() as connection:
        rows = connection.execute(
            "SELECT COUNT(*) FROM kiosk_remote_commands"
        ).fetchone()[0]
    assert rows == 1
