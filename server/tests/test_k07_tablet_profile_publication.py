import hashlib
import json
import sqlite3
import uuid

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from larenor_server.tablet_fleet import schema
from test_admin import activate, create as create_user


def root(app):
    context = app.state.core.context
    return f"/api/v1/tablet-fleet/{context.coreId}/{context.homeId}"


def register(client, pair, path):
    response = client.post(
        path + "/devices",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "registrationId": uuid.uuid4().hex,
            "name": "Profile tablet",
            "platform": "android",
            "managementMode": "standard",
            "clientVersion": "1.0.0",
            "appliedProfileRevision": 1,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()["tablet"]


def document(*, fullscreen=True, idle=300):
    return {
        "schemaVersion": 1,
        "fullscreen": fullscreen,
        "idleTimeoutSeconds": idle,
    }


def digest(app, device_id, value):
    context = app.state.core.context
    payload = [
        1,
        context.coreId,
        context.homeId,
        device_id,
        value["fullscreen"],
        value["idleTimeoutSeconds"],
    ]
    encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def publication(app, tablet, **changes):
    value = document()
    body = {
        "schemaVersion": 1,
        "expectedDeviceRevision": tablet["revision"],
        "expectedProfileRevision": 0,
        "documentDigest": digest(app, tablet["ref"]["id"], value),
        "document": value,
    }
    body.update(changes)
    return body


def test_exact_device_profile_publication_read_and_restart(server):
    app, client, settings, clock = server
    admin = ready(server)
    path = root(app)
    tablet = register(client, admin, path)
    device_id = tablet["ref"]["id"]
    endpoint = path + f"/devices/{device_id}/profile-publication"

    created = client.put(
        endpoint, headers=auth(admin), json=publication(app, tablet)
    )
    assert created.status_code == 200, created.text
    value = created.json()["publication"]
    assert value == {
        "schemaVersion": 1,
        "deviceId": device_id,
        "deviceRevision": 2,
        "revision": 2,
        "digest": digest(app, device_id, document()),
        "document": document(),
        "updatedAt": clock.now,
    }
    assert client.get(endpoint, headers=auth(admin)).json()["publication"] == value

    with app.state.core.db.connection() as connection:
        row = connection.execute(
            "SELECT nonce,ciphertext FROM managed_tablet_profiles"
        ).fetchone()
        assert len(row["nonce"]) == 12
        assert b"idleTimeoutSeconds" not in row["ciphertext"]

    with TestClient(create_app(settings)) as restarted:
        retained = restarted.get(endpoint, headers=auth(admin))
        assert retained.status_code == 200
        assert retained.json()["publication"] == value


def test_profile_publication_uses_exact_device_and_profile_cas(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    path = root(app)
    tablet = register(client, admin, path)
    device_id = tablet["ref"]["id"]
    endpoint = path + f"/devices/{device_id}/profile-publication"
    first_body = publication(app, tablet)
    first = client.put(endpoint, headers=auth(admin), json=first_body)
    assert first.status_code == 200

    stale_device = client.put(
        endpoint,
        headers=auth(admin),
        json={**first_body, "expectedProfileRevision": 2},
    )
    assert stale_device.status_code == 409
    assert stale_device.json()["error"]["code"] == "tablet_device_changed"

    changed_document = document(fullscreen=False, idle=600)
    second_body = {
        "schemaVersion": 1,
        "expectedDeviceRevision": 2,
        "expectedProfileRevision": 2,
        "documentDigest": digest(app, device_id, changed_document),
        "document": changed_document,
    }
    stale_profile = client.put(
        endpoint,
        headers=auth(admin),
        json={**second_body, "expectedProfileRevision": 1},
    )
    assert stale_profile.status_code == 409
    assert stale_profile.json()["error"]["code"] == "tablet_profile_changed"

    second = client.put(endpoint, headers=auth(admin), json=second_body)
    assert second.status_code == 200
    assert second.json()["publication"]["revision"] == 3
    assert second.json()["publication"]["deviceRevision"] == 3
    assert second.json()["publication"]["document"] == changed_document

    legacy_bump = client.put(
        path + f"/devices/{device_id}/profile",
        headers=auth(admin),
        json={
            "schemaVersion": 1,
            "expectedRevision": 3,
            "desiredProfileRevision": 4,
        },
    )
    assert legacy_bump.status_code == 409
    assert legacy_bump.json()["error"]["code"] == "tablet_profile_changed"


def test_profile_publication_auth_digest_and_schema_fail_closed(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    path = root(app)
    tablet = register(client, admin, path)
    device_id = tablet["ref"]["id"]
    endpoint = path + f"/devices/{device_id}/profile-publication"
    body = publication(app, tablet)

    create_user(client, admin)
    member = activate(client, "member")
    assert client.put(
        endpoint,
        headers=auth(member),
        json={**body, "documentDigest": "a" * 64},
    ).status_code == 403
    assert client.get(endpoint, headers=auth(member)).status_code == 404

    fresh = client.post(
        "/api/v1/auth/login",
        json={
            "username": "admin",
            "password": "Synthetic new password 2026",
            "deviceName": "Different family",
        },
    ).json()
    assert client.get(endpoint, headers=auth(fresh)).status_code == 404

    for changed in (
        {"schemaVersion": True},
        {"expectedDeviceRevision": True},
        {"expectedProfileRevision": True},
        {"documentDigest": "a" * 64},
        {"document": {**document(), "schemaVersion": True}},
        {"document": {**document(), "idleTimeoutSeconds": True}},
        {"document": {**document(), "unknown": "value"}},
        {"unknown": "value"},
    ):
        response = client.put(endpoint, headers=auth(admin), json={**body, **changed})
        assert response.status_code == 400, (changed, response.text)

    created = client.put(endpoint, headers=auth(admin), json=body)
    assert created.status_code == 200
    revoked = client.delete(
        path + f"/devices/{device_id}",
        headers=auth(admin),
        params={"expectedRevision": 2},
    )
    assert revoked.status_code == 204
    response = client.get(endpoint, headers=auth(admin))
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "tablet_device_inactive"


def test_profile_publication_tamper_blocks_read_and_restart(server):
    app, client, settings, _clock = server
    admin = ready(server)
    path = root(app)
    tablet = register(client, admin, path)
    device_id = tablet["ref"]["id"]
    endpoint = path + f"/devices/{device_id}/profile-publication"
    assert client.put(
        endpoint, headers=auth(admin), json=publication(app, tablet)
    ).status_code == 200

    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE managed_tablet_profiles SET digest=? WHERE device_id=?",
            ("f" * 64, device_id),
        )
    response = client.get(endpoint, headers=auth(admin))
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "tablet_fleet_storage_unavailable"
    with pytest.raises(StartupError, match="tablet_fleet_storage_invalid"):
        create_app(settings)


def test_tablet_fleet_schema_one_migrates_to_profile_storage():
    connection = sqlite3.connect(":memory:")
    connection.row_factory = sqlite3.Row
    connection.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY,value TEXT)")
    for statement in schema.LEGACY_TABLES.values():
        connection.execute(statement)
    connection.execute("INSERT INTO metadata VALUES('tablet_fleet_schema','1')")

    schema.migrate_tablet_fleet(connection)

    assert connection.execute(
        "SELECT value FROM metadata WHERE key='tablet_fleet_schema'"
    ).fetchone()["value"] == "2"
    names = {
        row["name"]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
    }
    assert "managed_tablet_profiles" in names
