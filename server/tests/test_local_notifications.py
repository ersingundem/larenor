import uuid

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.errors import ApiError
from larenor_server.errors import StartupError
from larenor_server.local_notifications.models import CreateNotification
from test_admin import activate, create as create_user


def scope(app):
    value = app.state.core.context
    return value.coreId, value.homeId


def root(app):
    core_id, home_id = scope(app)
    return f"/api/v1/local-notifications/{core_id}/{home_id}"


def register(client, pair, path, clock, registration=None, permission="granted", ttl=3600):
    registration = registration or uuid.uuid4().hex
    response = client.post(path + "/subscriptions", headers=auth(pair), json={
        "schemaVersion": 1, "registrationId": registration,
        "permission": permission, "expiresAt": clock() + ttl,
    })
    assert response.status_code == 201, response.text
    return response.json()["subscription"]


def event(recipient, key="fixture-event-key-01", **changes):
    body = {
        "schemaVersion": 1,
        "recipientUserId": recipient,
        "idempotencyKey": key,
        "category": "security",
        "sensitivity": "private",
        "title": "Front door",
        "body": "Motion was detected",
        "target": "/security/events/fixture",
    }
    body.update(changes)
    return body


def test_model_rejects_external_or_ambiguous_targets_before_storage():
    user = "a" * 32
    for target in ("https://example.invalid", "//example.invalid", "/security/../admin",
                   "/security?token=x", "/security#fragment", "/security//event"):
        with pytest.raises(ValidationError):
            CreateNotification.model_validate(event(user, target=target))


def test_subscription_permission_revision_and_session_lifecycle_fail_closed(server):
    app, client, _settings, clock = server
    admin = ready(server)
    path = root(app)
    denied = register(client, admin, path, clock, permission="denied")
    url = path + f"/subscriptions/{denied['ref']['id']}/events"
    response = client.get(url, headers=auth(admin), params={"expectedRevision": 1})
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "notification_subscription_inactive"

    updated = client.put(path + f"/subscriptions/{denied['ref']['id']}", headers=auth(admin), json={
        "schemaVersion": 1, "expectedRevision": 1, "permission": "granted",
        "expiresAt": clock() + 7200,
    })
    assert updated.status_code == 200
    assert updated.json()["subscription"]["revision"] == 2
    assert client.get(url, headers=auth(admin), params={"expectedRevision": 1}).status_code == 409
    assert client.get(url, headers=auth(admin), params={"expectedRevision": 2}).status_code == 200

    # A fresh login is the same user but a different device/session lifecycle.
    fresh = client.post("/api/v1/auth/login", json={
        "username": "admin", "password": "Synthetic new password 2026",
        "deviceName": "Replacement tablet",
    }).json()
    hidden = client.get(url, headers=auth(fresh), params={"expectedRevision": 2})
    assert hidden.status_code == 404


def test_pull_replay_ack_and_private_projection_survive_restart(server):
    app, client, settings, clock = server
    admin = ready(server)
    path = root(app)
    subscription = register(client, admin, path, clock)
    subscription_id = subscription["ref"]["id"]
    request = event(admin["user"]["id"])

    created = client.post(path + "/events", headers=auth(admin), json=request)
    assert created.status_code == 201, created.text
    exact_replay = client.post(path + "/events", headers=auth(admin), json=request)
    assert exact_replay.status_code == 201
    assert exact_replay.json() == created.json()
    conflict = client.post(path + "/events", headers=auth(admin), json={**request, "body": "Changed"})
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "notification_event_conflict"

    url = path + f"/subscriptions/{subscription_id}/events"
    page = client.get(url, headers=auth(admin), params={"expectedRevision": 1}).json()
    assert [item["sequence"] for item in page["events"]] == [1]
    item = page["events"][0]
    assert item["acknowledged"] is False
    assert (item["deliveryState"], item["readState"]) == ("delivered", "unread")
    assert item["publicProjection"] == {
        "title": "Larenor", "body": "", "target": None, "redacted": True}

    ack_body = {"schemaVersion": 1, "expectedSubscriptionRevision": 1,
                "sequences": [item["sequence"]]}
    first_ack = client.post(url.rsplit("/events", 1)[0] + "/acknowledgements",
                            headers=auth(admin), json=ack_body)
    second_ack = client.post(url.rsplit("/events", 1)[0] + "/acknowledgements",
                             headers=auth(admin), json=ack_body)
    assert first_ack.status_code == 200 and second_ack.json() == first_ack.json()
    assert client.get(url, headers=auth(admin), params={"expectedRevision": 1}).json()[
        "events"][0]["readState"] == "read"

    with TestClient(create_app(settings)) as restarted:
        retained = restarted.get(url, headers=auth(admin), params={"expectedRevision": 1})
        assert retained.status_code == 200
        assert retained.json()["events"][0]["acknowledged"] is True


def test_authority_is_user_scoped_and_member_cannot_publish(server):
    app, client, _settings, clock = server
    admin = ready(server)
    create_user(client, admin)
    member = activate(client, "member")
    path = root(app)
    admin_subscription = register(client, admin, path, clock)
    member_subscription = register(client, member, path, clock)
    request = event(member["user"]["id"])

    denied = client.post(path + "/events", headers=auth(member), json=request)
    assert denied.status_code == 403
    published = client.post(path + "/events", headers=auth(admin), json=request)
    assert published.status_code == 201

    unseen = client.post(
        path + f"/subscriptions/{member_subscription['ref']['id']}/acknowledgements",
        headers=auth(member), json={"schemaVersion": 1,
            "expectedSubscriptionRevision": 1,
            "sequences": [published.json()["notification"]["sequence"]]},
    )
    assert unseen.status_code == 409
    assert unseen.json()["error"]["code"] == "notification_not_delivered"

    own = client.get(path + f"/subscriptions/{member_subscription['ref']['id']}/events",
                     headers=auth(member), params={"expectedRevision": 1})
    assert own.status_code == 200 and len(own.json()["events"]) == 1
    admin_view = client.get(path + f"/subscriptions/{admin_subscription['ref']['id']}/events",
                            headers=auth(admin), params={"expectedRevision": 1})
    assert admin_view.status_code == 200 and admin_view.json()["events"] == []
    cross = client.get(path + f"/subscriptions/{member_subscription['ref']['id']}/events",
                       headers=auth(admin), params={"expectedRevision": 1})
    assert cross.status_code == 404


def test_expiry_revoke_and_stale_ack_are_rejected_without_transport(server):
    app, client, _settings, clock = server
    admin = ready(server)
    path = root(app)
    subscription = register(client, admin, path, clock, ttl=60)
    subscription_id = subscription["ref"]["id"]
    assert not hasattr(app.state.core.local_notifications, "transport")
    created = client.post(path + "/events", headers=auth(admin),
                          json=event(admin["user"]["id"])).json()["notification"]
    ack = path + f"/subscriptions/{subscription_id}/acknowledgements"

    clock.now += 61
    expired = client.post(ack, headers=auth(admin), json={
        "schemaVersion": 1, "expectedSubscriptionRevision": 1,
        "sequences": [created["sequence"]],
    })
    assert expired.status_code == 409

    clock.now -= 61
    revoked = client.delete(path + f"/subscriptions/{subscription_id}", headers=auth(admin),
                            params={"expectedRevision": 1})
    assert revoked.status_code == 204
    stale = client.post(ack, headers=auth(admin), json={
        "schemaVersion": 1, "expectedSubscriptionRevision": 1,
        "sequences": [created["sequence"]],
    })
    assert stale.status_code == 409
    assert stale.json()["error"]["code"] == "notification_subscription_changed"


def test_direct_service_revalidates_principal_and_scope(server):
    app, client, _settings, clock = server
    admin = ready(server)
    actor = app.state.core.auth.authenticate(admin["accessToken"])
    core_id, home_id = scope(app)
    body = {"schemaVersion": 1, "registrationId": uuid.uuid4().hex,
            "permission": "granted", "expiresAt": clock() + 3600}
    with pytest.raises(ApiError, match="not_found"):
        app.state.core.local_notifications.register(actor, "f" * 32, home_id, body)
    app.state.core.auth.logout(actor)
    with pytest.raises(ApiError, match="invalid_session"):
        app.state.core.local_notifications.register(actor, core_id, home_id, body)


def test_payload_is_encrypted_and_tamper_blocks_reads_and_restart(server):
    app, client, settings, clock = server
    admin = ready(server)
    path = root(app)
    subscription = register(client, admin, path, clock)
    response = client.post(path + "/events", headers=auth(admin),
                           json=event(admin["user"]["id"]))
    assert response.status_code == 201
    with app.state.core.db.transaction() as connection:
        row = connection.execute(
            "SELECT sequence,nonce,ciphertext FROM local_notification_events"
        ).fetchone()
        assert b"Front door" not in row["ciphertext"]
        damaged = bytearray(row["ciphertext"])
        damaged[-1] ^= 1
        connection.execute("UPDATE local_notification_events SET ciphertext=? WHERE sequence=?",
                           (bytes(damaged), row["sequence"]))
    url = path + f"/subscriptions/{subscription['ref']['id']}/events"
    broken = client.get(url, headers=auth(admin), params={"expectedRevision": 1})
    assert broken.status_code == 503
    assert broken.json()["error"]["code"] == "notification_storage_unavailable"
    with pytest.raises(StartupError, match="local_notification_storage_invalid"):
        create_app(settings)
