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


def registration(*, mode="standard"):
    return {
        "schemaVersion": 1,
        "registrationId": uuid.uuid4().hex,
        "name": "Kitchen tablet",
        "platform": "android",
        "managementMode": mode,
        "clientVersion": "1.0.0",
        "appliedProfileRevision": 1,
    }


def register(client, principal, path, *, mode="standard"):
    response = client.post(
        path + "/devices", headers=auth(principal), json=registration(mode=mode)
    )
    assert response.status_code == 201, response.text
    return response.json()["tablet"]


def test_registered_identity_last_seen_and_capabilities_are_read_only_state(server):
    app, client, settings, clock = server
    admin = ready(server)
    path = root(app)
    standard = register(client, admin, path)
    owner = register(client, admin, path, mode="deviceOwner")
    assert standard["capabilities"] == ["notifications", "kiosk", "media", "screen"]
    assert owner["capabilities"][-2:] == ["appRestart", "kioskLock"]
    assert standard["lastSeenAt"] == clock.now

    listed = client.get(path + "/devices", headers=auth(admin)).json()["tablets"]
    assert [item["ref"]["id"] for item in listed] == [
        standard["ref"]["id"], owner["ref"]["id"]
    ]
    assert all("token" not in str(item).lower() for item in listed)
    with TestClient(create_app(settings)) as restarted:
        retained = restarted.get(path + "/devices", headers=auth(admin))
        assert retained.status_code == 200
        assert len(retained.json()["tablets"]) == 2


def test_owner_admin_authority_and_tamper_evident_audit_fail_closed(server):
    app, client, settings, _clock = server
    admin = ready(server)
    path = root(app)
    tablet = register(client, admin, path)
    create_user(client, admin)
    member = activate(client, "member")
    assert client.get(path + "/devices", headers=auth(member)).status_code == 403
    assert client.get(path + "/audit", headers=auth(member)).status_code == 403
    audit = client.get(path + "/audit", headers=auth(admin))
    assert audit.status_code == 200
    assert audit.json()["events"][0]["action"] == "registered"
    assert "token" not in audit.text.lower()

    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE managed_tablet_events SET actor_id='mallory' WHERE sequence=1"
        )
    with pytest.raises(StartupError, match="tablet_fleet_storage_invalid"):
        create_app(settings)


def test_command_policy_revision_expiry_and_idempotency_gate_before_delivery(server):
    app, client, _settings, clock = server
    admin = ready(server)
    path = root(app)
    tablet = register(client, admin, path)
    device = tablet["ref"]["id"]
    endpoint = path + f"/devices/{device}/commands"
    base = {
        "schemaVersion": 1,
        "expectedDeviceRevision": 1,
        "expectedPolicyRevision": 1,
        "requestKey": "refresh-dashboard-request-01",
        "command": "refreshDashboard",
        "expiresAt": clock.now + 60,
    }
    stale = client.post(endpoint, headers=auth(admin), json={
        **base, "expectedPolicyRevision": 2,
    })
    assert stale.status_code == 409
    assert stale.json()["error"]["code"] == "tablet_policy_changed"
    expired = client.post(endpoint, headers=auth(admin), json={
        **base, "expiresAt": clock.now - 1,
    })
    assert expired.status_code == 409
    assert expired.json()["error"]["code"] == "tablet_command_expired"

    issued = client.post(endpoint, headers=auth(admin), json=base)
    replay = client.post(endpoint, headers=auth(admin), json=base)
    assert issued.status_code == 201 and replay.json() == issued.json()
    changed = client.post(endpoint, headers=auth(admin), json={
        **base, "expiresAt": clock.now + 120,
    })
    assert changed.status_code == 409
    assert changed.json()["error"]["code"] == "tablet_command_conflict"

    clock.now += 61
    polled = client.post(
        endpoint + "/poll", headers=auth(admin), json={
            "schemaVersion": 1, "expectedDeviceRevision": 1,
            "after": 0, "limit": 20,
        },
    )
    assert polled.status_code == 200
    assert polled.json()["commands"] == []
    audit = client.get(path + "/audit", headers=auth(admin)).json()["events"]
    assert audit[-1]["action"] == "command_expired"

