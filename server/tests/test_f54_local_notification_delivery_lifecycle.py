import uuid

import pytest
from conftest import auth, ready


def _root(app):
    context = app.state.core.context
    return f"/api/v1/local-notifications/{context.coreId}/{context.homeId}"


def _register(client, pair, path, clock, *, ttl=3600):
    response = client.post(path + "/subscriptions", headers=auth(pair), json={
        "schemaVersion": 1,
        "registrationId": uuid.uuid4().hex,
        "permission": "granted",
        "expiresAt": clock() + ttl,
    })
    assert response.status_code == 201, response.text
    return response.json()["subscription"]


def _event(user_id, key):
    return {
        "schemaVersion": 1,
        "recipientUserId": user_id,
        "idempotencyKey": key,
        "category": "security",
        "sensitivity": "public",
        "title": "Front door",
        "body": "Motion was detected",
        "target": "/security/events/f54",
    }


def _events(path, subscription):
    return path + f"/subscriptions/{subscription['ref']['id']}/events"


def test_expired_subscription_cannot_be_renewed_or_reactivated(server):
    app, client, _settings, clock = server
    admin = ready(server)
    path = _root(app)
    subscription = _register(client, admin, path, clock, ttl=60)
    subscription_id = subscription["ref"]["id"]

    clock.now += 61
    response = client.put(
        path + f"/subscriptions/{subscription_id}",
        headers=auth(admin),
        json={
            "schemaVersion": 1,
            "expectedRevision": 1,
            "permission": "granted",
            "expiresAt": clock() + 3600,
        },
    )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "notification_subscription_inactive"
    with app.state.core.db.connection() as connection:
        row = connection.execute(
            "SELECT revision,expires_at FROM local_notification_subscriptions WHERE id=?",
            (subscription_id,),
        ).fetchone()
    assert (row["revision"], row["expires_at"]) == (1, subscription["expiresAt"])


@pytest.mark.parametrize("retirement", ["revoked", "expired"])
def test_replacement_subscription_does_not_replay_retired_delivery(server, retirement):
    app, client, _settings, clock = server
    admin = ready(server)
    path = _root(app)
    old = _register(client, admin, path, clock, ttl=60)
    created = client.post(
        path + "/events",
        headers=auth(admin),
        json=_event(admin["user"]["id"], f"f54-retired-{retirement}"),
    )
    assert created.status_code == 201, created.text
    delivered = client.get(
        _events(path, old), headers=auth(admin), params={"expectedRevision": 1}
    )
    assert delivered.status_code == 200
    assert len(delivered.json()["events"]) == 1

    if retirement == "revoked":
        response = client.delete(
            path + f"/subscriptions/{old['ref']['id']}",
            headers=auth(admin),
            params={"expectedRevision": 1},
        )
        assert response.status_code == 204
        clock.now += 1
    else:
        clock.now += 61

    replacement = _register(client, admin, path, clock)
    replay = client.get(
        _events(path, replacement), headers=auth(admin), params={"expectedRevision": 1}
    )

    assert replay.status_code == 200
    assert replay.json()["events"] == []
    with app.state.core.db.connection() as connection:
        count = connection.execute(
            "SELECT COUNT(*) FROM local_notification_acks WHERE subscription_id=?",
            (replacement["ref"]["id"],),
        ).fetchone()[0]
    assert count == 0


def test_replacement_pull_fails_closed_for_corrupted_retired_owner(server):
    app, client, _settings, clock = server
    admin = ready(server)
    path = _root(app)
    old = _register(client, admin, path, clock)
    created = client.post(
        path + "/events",
        headers=auth(admin),
        json=_event(admin["user"]["id"], "f54-corrupt-retired-owner"),
    )
    assert created.status_code == 201, created.text
    delivered = client.get(
        _events(path, old), headers=auth(admin), params={"expectedRevision": 1}
    )
    assert delivered.status_code == 200
    revoked = client.delete(
        path + f"/subscriptions/{old['ref']['id']}",
        headers=auth(admin),
        params={"expectedRevision": 1},
    )
    assert revoked.status_code == 204
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE local_notification_subscriptions SET envelope_tag=? WHERE id=?",
            ("0" * 64, old["ref"]["id"]),
        )
    replacement = _register(client, admin, path, clock)

    response = client.get(
        _events(path, replacement),
        headers=auth(admin),
        params={"expectedRevision": 1},
    )

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "notification_storage_unavailable"


def test_repeated_pull_reuses_receipt_identity_without_second_delivery_effect(server):
    app, client, _settings, clock = server
    admin = ready(server)
    path = _root(app)
    subscription = _register(client, admin, path, clock)
    subscription_id = subscription["ref"]["id"]
    created = client.post(
        path + "/events",
        headers=auth(admin),
        json=_event(admin["user"]["id"], "f54-stable-delivery-id"),
    )
    assert created.status_code == 201, created.text

    first = client.get(
        _events(path, subscription), headers=auth(admin), params={"expectedRevision": 1}
    )
    assert first.status_code == 200
    first_event = first.json()["events"][0]
    with app.state.core.db.connection() as connection:
        first_delivery = connection.execute(
            "SELECT delivered_at FROM local_notification_acks "
            "WHERE subscription_id=? AND sequence=?",
            (subscription_id, first_event["sequence"]),
        ).fetchone()["delivered_at"]

    clock.now += 10
    second = client.get(
        _events(path, subscription), headers=auth(admin), params={"expectedRevision": 1}
    )
    assert second.status_code == 200
    second_event = second.json()["events"][0]
    assert (second_event["id"], second_event["sequence"]) == (
        first_event["id"],
        first_event["sequence"],
    )
    with app.state.core.db.connection() as connection:
        rows = connection.execute(
            "SELECT delivered_at FROM local_notification_acks "
            "WHERE subscription_id=? AND sequence=?",
            (subscription_id, first_event["sequence"]),
        ).fetchall()
    assert [row["delivered_at"] for row in rows] == [first_delivery]
