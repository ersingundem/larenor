import sqlite3
import uuid

import pytest
from fastapi.testclient import TestClient

from conftest import auth
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from larenor_server.sound_events.repository import SoundEventRepository
from support.f45_sound_fixture import SoundFixture
from test_f45_frigate_normal_core import configured


@pytest.fixture
def frigate():
    value = SoundFixture()
    yield value
    value.close()
    assert value.errors == []


def _notifications_root(app):
    scope = app.state.core.context
    return f"/api/v1/local-notifications/{scope.coreId}/{scope.homeId}"


def _enable_notifications(client, actor, sound_root):
    snapshot = client.get(sound_root, headers=auth(actor)).json()
    response = client.put(sound_root + "/policy", headers=auth(actor), json={
        "schemaVersion": 1,
        "requestId": uuid.uuid4().hex,
        "expectedRepositoryRevision": snapshot["repositoryRevision"],
        "expectedPolicyRevision": snapshot["policy"]["revision"],
        "notificationsEnabled": True,
        "barkEnabled": True,
        "noiseEnabled": True,
        "mutedUntilMs": None,
        "sourceClipRetention": "never",
    })
    assert response.status_code == 200, response.text


def _register(client, actor, root, clock):
    response = client.post(root + "/subscriptions", headers=auth(actor), json={
        "schemaVersion": 1,
        "registrationId": uuid.uuid4().hex,
        "permission": "granted",
        "expiresAt": clock() + 3600,
    })
    assert response.status_code == 201, response.text
    return response.json()["subscription"]


def _events(client, actor, root, subscription):
    response = client.get(
        root + f"/subscriptions/{subscription['ref']['id']}/events",
        headers=auth(actor),
        params={"expectedRevision": subscription["revision"]},
    )
    assert response.status_code == 200, response.text
    return response.json()["events"]


def test_real_frigate_events_handoff_once_to_private_f54_and_survive_restart(
    server, frigate
):
    app, client, settings, clock = server
    actor, sound_root, _source = configured(server, frigate)
    notification_root = _notifications_root(app)
    subscription = _register(client, actor, notification_root, clock)
    _enable_notifications(client, actor, sound_root)

    refreshed = client.post(sound_root + "/source/refresh", headers=auth(actor))
    assert refreshed.status_code == 200, refreshed.text
    assert refreshed.json()["importedEvents"] == 2

    delivered = _events(client, actor, notification_root, subscription)
    assert len(delivered) == 2
    assert {event["category"] for event in delivered} == {"sound_event"}
    assert {event["sensitivity"] for event in delivered} == {"private"}
    assert all(event["publicProjection"] == {
        "title": "Larenor", "body": "", "target": None, "redacted": True,
    } for event in delivered)
    snapshot = client.get(sound_root, headers=auth(actor)).json()
    assert len(snapshot["events"]) == 2
    assert all(event["automationVerified"] is True for event in snapshot["events"])

    repeated = client.post(sound_root + "/source/refresh", headers=auth(actor))
    assert repeated.status_code == 200, repeated.text
    assert repeated.json()["importedEvents"] == 0
    assert len(_events(client, actor, notification_root, subscription)) == 2

    with TestClient(create_app(settings)) as restarted:
        assert len(_events(
            restarted, actor, notification_root, subscription
        )) == 2
        retained = restarted.get(sound_root, headers=auth(actor)).json()["events"]
        assert all(event["automationVerified"] is True for event in retained)


def test_lost_f54_ack_reconciles_by_exact_idempotency_without_resend(
    server, frigate, monkeypatch
):
    app, client, _settings, clock = server
    actor, sound_root, _source = configured(server, frigate)
    notification_root = _notifications_root(app)
    subscription = _register(client, actor, notification_root, clock)
    _enable_notifications(client, actor, sound_root)
    repository = app.state.core.sound_events
    mark = repository._mark_notification_delivered
    attempts = 0

    def lose_first_receipt(*args, **kwargs):
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            raise ValueError("simulated_lost_ack")
        return mark(*args, **kwargs)

    monkeypatch.setattr(repository, "_mark_notification_delivered", lose_first_receipt)
    failed = client.post(sound_root + "/source/refresh", headers=auth(actor))
    assert failed.status_code == 503, failed.text
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM local_notification_events"
        ).fetchone()[0] == 1

    recovered = client.post(sound_root + "/source/refresh", headers=auth(actor))
    assert recovered.status_code == 200, recovered.text
    assert recovered.json()["importedEvents"] == 0
    assert len(_events(client, actor, notification_root, subscription)) == 2
    assert all(item["automationVerified"] is True for item in client.get(
        sound_root, headers=auth(actor)
    ).json()["events"])


def test_session_revoked_inside_f54_transaction_rolls_back_notification(
    server, frigate, monkeypatch
):
    app, client, _settings, _clock = server
    actor, sound_root, _source = configured(server, frigate)
    _enable_notifications(client, actor, sound_root)
    writer = app.state.core.local_notifications
    append = writer.append_internal

    def revoke_before_return(connection, value):
        result = append(connection, value)
        connection.execute(
            "UPDATE session_families SET revoked_at=? WHERE id=?",
            (1788609600.0, actor["sessionFamilyId"]),
        )
        return result

    monkeypatch.setattr(writer, "append_internal", revoke_before_return)
    failed = client.post(sound_root + "/source/refresh", headers=auth(actor))
    assert failed.status_code in {401, 409, 503}, failed.text
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM local_notification_events"
        ).fetchone()[0] == 0


def test_source_revision_drift_after_ingest_prevents_f54_append(
    server, frigate, monkeypatch
):
    app, client, _settings, _clock = server
    actor, sound_root, _source = configured(server, frigate)
    _enable_notifications(client, actor, sound_root)
    principal = app.state.core.auth.authenticate(actor["accessToken"])
    repository = app.state.core.sound_events
    record = repository.record_batch

    def record_then_revoke(authority, events, **kwargs):
        inserted = record(authority, events, **kwargs)
        source = app.state.core.sound_event_source_store.get(principal)
        revoked = source.model_copy(update={
            "revision": source.revision + 1,
            "consentRevision": source.consentRevision + 1,
            "consentGranted": False,
        })
        app.state.core.sound_event_source_store.put(
            principal, revoked, source.revision
        )
        return inserted

    monkeypatch.setattr(repository, "record_batch", record_then_revoke)
    failed = client.post(sound_root + "/source/refresh", headers=auth(actor))
    assert failed.status_code in {409, 503}, failed.text
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM local_notification_events"
        ).fetchone()[0] == 0


def test_camera_authority_drift_inside_f54_transaction_rolls_back_notification(
    server, frigate, monkeypatch
):
    app, client, _settings, _clock = server
    actor, sound_root, source = configured(server, frigate)
    _enable_notifications(client, actor, sound_root)
    writer = app.state.core.local_notifications
    append = writer.append_internal

    def revoke_camera_after_append(connection, value):
        result = append(connection, value)
        resources = app.state.core.home_resources
        row, _ref, data = resources._target(
            connection, source["cameraResourceId"]
        )
        changed = dict(row)
        changed["revision"] += 1
        resources._save(connection, changed, data)
        resources._bump(connection)
        return result

    monkeypatch.setattr(writer, "append_internal", revoke_camera_after_append)
    failed = client.post(sound_root + "/source/refresh", headers=auth(actor))
    assert failed.status_code in {403, 409, 503}, failed.text
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM local_notification_events"
        ).fetchone()[0] == 0


def test_false_alarm_cancels_pending_handoff_before_any_f54_event(
    server, frigate, monkeypatch
):
    app, client, _settings, _clock = server
    actor, sound_root, _source = configured(server, frigate)
    _enable_notifications(client, actor, sound_root)
    repository = app.state.core.sound_events
    dispatch = repository.dispatch_notifications
    monkeypatch.setattr(
        repository, "dispatch_notifications", lambda *args, **kwargs: 0
    )
    assert client.post(
        sound_root + "/source/refresh", headers=auth(actor)
    ).status_code == 200
    snapshot = client.get(sound_root, headers=auth(actor)).json()
    event = snapshot["events"][0]
    false_alarm = client.post(
        sound_root + f"/{event['eventId']}/feedback",
        headers=auth(actor),
        json={
            "schemaVersion": 1,
            "requestId": uuid.uuid4().hex,
            "expectedRepositoryRevision": snapshot["repositoryRevision"],
            "expectedEventRevision": event["eventRevision"],
            "classification": "false_alarm",
        },
    )
    assert false_alarm.status_code == 200, false_alarm.text
    monkeypatch.setattr(repository, "dispatch_notifications", dispatch)

    assert client.post(
        sound_root + "/source/refresh", headers=auth(actor)
    ).status_code == 200
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM local_notification_events"
        ).fetchone()[0] == 1
    with repository._connection() as connection:
        states = {
            row["event_id"]: row["state"] for row in connection.execute(
                "SELECT event_id,state FROM sound_event_notification_outbox"
            )
        }
    assert states[event["eventId"]] == "cancelled"
    assert sorted(states.values()) == ["cancelled", "delivered"]


def test_outbox_migrates_from_previous_schema_and_tamper_fails_closed(server):
    app, _client, settings, _clock = server
    path = app.state.core.sound_events.path
    with sqlite3.connect(path) as connection:
        connection.execute("DROP TABLE sound_event_notification_outbox")
    reopened = SoundEventRepository(
        path,
        settings.key_file.read_bytes(),
        app.state.core.db,
        app.state.core.auth,
        app.state.core.context,
        settings.clock,
        notification_writer=app.state.core.local_notifications,
    )
    with reopened._connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM sound_event_notification_outbox"
        ).fetchone()[0] == 0
        columns = {
            row["name"] for row in connection.execute(
                "PRAGMA table_info(sound_event_notification_outbox)"
            )
        }
    assert {"event_id", "state", "notification_sequence"} <= columns

    with sqlite3.connect(path) as connection:
        connection.execute(
            "INSERT INTO sound_event_notification_outbox VALUES(?,?,?,?,?,?,?,?,?)",
            ("f" * 32, "e" * 32, "d" * 32, 1, 1, "pending", None, None, "0" * 64),
        )
    with pytest.raises(StartupError, match="sound_event_storage_invalid"):
        SoundEventRepository(
            path,
            settings.key_file.read_bytes(),
            app.state.core.db,
            app.state.core.auth,
            app.state.core.context,
            settings.clock,
            notification_writer=app.state.core.local_notifications,
        )
