import uuid

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from test_admin import activate, create as create_user


def root(app):
    context = app.state.core.context
    return f"/api/v1/tablet-fleet/{context.coreId}/{context.homeId}"


def registration(device_id=None, mode="standard", name="Kitchen tablet"):
    return {
        "schemaVersion": 1,
        "registrationId": device_id or uuid.uuid4().hex,
        "name": name,
        "platform": "android",
        "managementMode": mode,
        "clientVersion": "1.0.0",
        "appliedProfileRevision": 1,
    }


def register(client, pair, path, **changes):
    body = registration(**changes)
    response = client.post(path + "/devices", headers=auth(pair), json=body)
    assert response.status_code == 201, response.text
    return body, response.json()["tablet"]


def test_registration_profile_heartbeat_and_restart_are_exact(server):
    app, client, settings, _clock = server
    admin = ready(server)
    path = root(app)
    body, tablet = register(client, admin, path)
    assert tablet["revision"] == 1
    assert tablet["profileState"] == "current"
    assert tablet["capabilities"] == ["notifications", "kiosk", "media", "screen"]
    assert "appRestart" not in tablet["capabilities"]

    # Exact registration replay is idempotent; the identifier cannot be reused
    # to replace the encrypted record or silently promote its management mode.
    assert client.post(path + "/devices", headers=auth(admin), json=body).json()["tablet"] == tablet
    conflict = client.post(path + "/devices", headers=auth(admin), json={
        **body, "managementMode": "deviceOwner",
    })
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "tablet_registration_replay"

    profile = client.put(
        path + f"/devices/{tablet['ref']['id']}/profile",
        headers=auth(admin),
        json={"schemaVersion": 1, "expectedRevision": 1, "desiredProfileRevision": 2},
    )
    assert profile.status_code == 200
    assert profile.json()["tablet"]["revision"] == 2
    assert profile.json()["tablet"]["profileState"] == "updateRequired"
    stale = client.post(
        path + f"/devices/{tablet['ref']['id']}/heartbeat",
        headers=auth(admin),
        json={"schemaVersion": 1, "expectedRevision": 1,
              "clientVersion": "1.0.1", "appliedProfileRevision": 2},
    )
    assert stale.status_code == 409
    current = client.post(
        path + f"/devices/{tablet['ref']['id']}/heartbeat",
        headers=auth(admin),
        json={"schemaVersion": 1, "expectedRevision": 2,
              "clientVersion": "1.0.1", "appliedProfileRevision": 2},
    )
    assert current.status_code == 200
    assert current.json()["tablet"]["profileState"] == "current"

    with app.state.core.db.connection() as connection:
        row = connection.execute("SELECT nonce,ciphertext FROM managed_tablets").fetchone()
        assert b"Kitchen tablet" not in row["ciphertext"]
        assert len(row["nonce"]) == 12
    with TestClient(create_app(settings)) as restarted:
        retained = restarted.get(path + "/devices", headers=auth(admin))
        assert retained.status_code == 200
        assert retained.json()["tablets"][0]["clientVersion"] == "1.0.1"


def test_command_delivery_is_bounded_replay_safe_and_capability_aware(server):
    app, client, _settings, clock = server
    admin = ready(server)
    path = root(app)
    _body, standard = register(client, admin, path)
    device_id = standard["ref"]["id"]
    denied = client.post(path + f"/devices/{device_id}/commands", headers=auth(admin), json={
        "schemaVersion": 1, "expectedDeviceRevision": 1,
        "expectedPolicyRevision": 1, "expiresAt": clock.now + 60,
        "requestKey": "restart-standard-01", "command": "restartClient",
    })
    assert denied.status_code == 409
    assert denied.json()["error"]["code"] == "tablet_capability_unavailable"

    request = {"schemaVersion": 1, "expectedDeviceRevision": 1,
               "expectedPolicyRevision": 1, "expiresAt": clock.now + 60,
               "requestKey": "sync-profile-request-01", "command": "syncProfile"}
    issued = client.post(path + f"/devices/{device_id}/commands",
                         headers=auth(admin), json=request)
    replay = client.post(path + f"/devices/{device_id}/commands",
                         headers=auth(admin), json=request)
    assert issued.status_code == 201 and replay.json() == issued.json()
    conflict = client.post(path + f"/devices/{device_id}/commands", headers=auth(admin),
                           json={**request, "command": "refreshDashboard"})
    assert conflict.status_code == 409

    poll_body = {"schemaVersion": 1, "expectedDeviceRevision": 1,
                 "expectedPolicyRevision": 1, "after": 0, "limit": 20}
    first = client.post(path + f"/devices/{device_id}/commands/poll",
                        headers=auth(admin), json=poll_body)
    lost_response_retry = client.post(path + f"/devices/{device_id}/commands/poll",
                                      headers=auth(admin), json=poll_body)
    assert first.status_code == 200 and lost_response_retry.json() == first.json()
    command = first.json()["commands"][0]
    assert command["state"] == "delivered"

    completed_body = {"schemaVersion": 1, "expectedDeviceRevision": 1,
                      "expectedPolicyRevision": 1,
                      "sequence": command["sequence"], "result": "succeeded",
                      "appliedProfileRevision": 1}
    completed = client.post(
        path + f"/devices/{device_id}/commands/{command['id']}/complete",
        headers=auth(admin), json=completed_body)
    exact_replay = client.post(
        path + f"/devices/{device_id}/commands/{command['id']}/complete",
        headers=auth(admin), json=completed_body)
    assert completed.status_code == 200 and exact_replay.json() == completed.json()
    changed = client.post(
        path + f"/devices/{device_id}/commands/{command['id']}/complete",
        headers=auth(admin), json={**completed_body, "result": "failed"})
    assert changed.status_code == 409
    after = client.post(path + f"/devices/{device_id}/commands/poll", headers=auth(admin),
                        json={**poll_body, "after": command["sequence"]})
    assert after.json()["commands"] == []

    _owner_body, owner = register(client, admin, path, mode="deviceOwner", name="Wall panel")
    elevated = client.post(path + f"/devices/{owner['ref']['id']}/commands",
                           headers=auth(admin), json={
        "schemaVersion": 1, "expectedDeviceRevision": 1,
        "expectedPolicyRevision": 1, "expiresAt": clock.now + 60,
        "requestKey": "owner-restart-request-01", "command": "restartClient",
    })
    assert elevated.status_code == 201
    assert elevated.json()["command"]["requiredMode"] == "deviceOwner"


def test_scope_session_role_and_revocation_fail_closed(server):
    app, client, _settings, clock = server
    admin = ready(server)
    path = root(app)
    _body, tablet = register(client, admin, path)
    device_id = tablet["ref"]["id"]

    wrong_scope = path.replace(app.state.core.context.homeId, "f" * 32)
    assert client.post(wrong_scope + f"/devices/{device_id}/heartbeat", headers=auth(admin), json={
        "schemaVersion": 1, "expectedRevision": 1,
        "clientVersion": "1.0.1", "appliedProfileRevision": 1,
    }).status_code == 404

    fresh = client.post("/api/v1/auth/login", json={
        "username": "admin", "password": "Synthetic new password 2026",
        "deviceName": "Different tablet",
    }).json()
    cross_family = client.post(path + f"/devices/{device_id}/commands/poll",
                               headers=auth(fresh), json={
        "schemaVersion": 1, "expectedDeviceRevision": 1,
        "expectedPolicyRevision": 1, "after": 0, "limit": 20,
    })
    assert cross_family.status_code == 404

    create_user(client, admin)
    member = activate(client, "member")
    assert client.get(path + "/devices", headers=auth(member)).status_code == 403
    assert client.post(path + f"/devices/{device_id}/commands", headers=auth(member), json={
        "schemaVersion": 1, "expectedDeviceRevision": 1,
        "expectedPolicyRevision": 1, "expiresAt": clock.now + 60,
        "requestKey": "member-command-request-01", "command": "syncProfile",
    }).status_code == 403

    revoked = client.delete(path + f"/devices/{device_id}", headers=auth(admin),
                            params={"expectedRevision": 1})
    assert revoked.status_code == 204
    heartbeat = client.post(path + f"/devices/{device_id}/heartbeat", headers=auth(admin), json={
        "schemaVersion": 1, "expectedRevision": 2,
        "clientVersion": "1.0.1", "appliedProfileRevision": 1,
    })
    assert heartbeat.status_code == 409
    assert heartbeat.json()["error"]["code"] == "tablet_device_inactive"

    malformed = client.post(path + "/devices", headers=auth(admin), json={
        **registration(), "managementMode": "root", "secret": "must-not-be-accepted",
    })
    assert malformed.status_code == 400


def test_tampered_device_or_command_blocks_reads_and_restart(server):
    app, client, settings, clock = server
    admin = ready(server)
    path = root(app)
    _body, tablet = register(client, admin, path)
    device_id = tablet["ref"]["id"]
    command = client.post(path + f"/devices/{device_id}/commands", headers=auth(admin), json={
        "schemaVersion": 1, "expectedDeviceRevision": 1,
        "expectedPolicyRevision": 1, "expiresAt": clock.now + 60,
        "requestKey": "tamper-command-request-01", "command": "syncProfile",
    }).json()["command"]
    with app.state.core.db.transaction() as connection:
        connection.execute("UPDATE managed_tablet_commands SET command='refreshDashboard' WHERE id=?",
                           (command["id"],))
    broken = client.post(path + f"/devices/{device_id}/commands/poll", headers=auth(admin), json={
        "schemaVersion": 1, "expectedDeviceRevision": 1,
        "expectedPolicyRevision": 1, "after": 0, "limit": 20,
    })
    assert broken.status_code == 503
    with pytest.raises(StartupError, match="tablet_fleet_storage_invalid"):
        create_app(settings)
