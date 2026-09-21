import sqlite3

from conftest import auth, ready

from larenor_server.sound_events import SoundClassifierBinding, SoundEvent, SoundEventAuthority


ROOM = "5" * 32
DEVICE = "6" * 32
MODEL = "7" * 32
EVENT = "8" * 32
REQUEST = "9" * 32


def _seed(server):
    app, _client, _settings, _clock = server
    pair = ready(server)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    context = app.state.core.context
    with app.state.core.db.connection() as connection:
        account_revision = connection.execute(
            "SELECT revision FROM users WHERE id=?", (actor.id,)
        ).fetchone()["revision"]
    authority = SoundEventAuthority(
        schemaVersion=1,
        coreId=context.coreId,
        homeId=context.homeId,
        homeRevision=1,
        accountId=actor.id,
        accountRevision=account_revision,
        memberRevision=account_revision,
        sessionFamilyId=actor.family_id,
        accessibleRoomIds=[ROOM],
        accessibleDeviceIds=[DEVICE],
        active=True,
        canObserve=True,
    )
    event = SoundEvent(
        schemaVersion=1,
        eventId=EVENT,
        coreId=context.coreId,
        homeId=context.homeId,
        roomId=ROOM,
        roomRevision=2,
        deviceId=DEVICE,
        deviceRevision=3,
        modelId=MODEL,
        modelRevision=4,
        providerRevision=5,
        policyRevision=6,
        consentRevision=7,
        className="bark",
        confidence=0.91,
        observedAtMs=10_000,
        evidenceDigest="a" * 64,
        retentionExpiresAtMs=10_000_000_000_000,
        automationVerified=True,
    )
    app.state.core.sound_events.record(authority, event)
    root = f"/api/v1/sound-events/{context.coreId}/{context.homeId}"
    return pair, actor, authority, root


def test_authenticated_filters_are_persistent_bounded_and_audio_free(server):
    app, client, settings, _clock = server
    pair, actor, authority, root = _seed(server)

    assert client.get(root).status_code == 401
    response = client.get(
        root,
        headers=auth(pair),
        params={"roomId": ROOM, "className": "bark", "acknowledged": "false"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["authority"]["accountId"] == actor.id
    assert body["authority"]["sessionFamilyId"] == actor.family_id
    assert body["events"][0]["eventId"] == EVENT
    assert body["events"][0]["acknowledged"] is False
    assert "audio" not in response.text.lower()

    from larenor_server.sound_events.repository import SoundEventRepository

    reopened = SoundEventRepository(
        settings.data_dir / "sound-events.db",
        settings.key_file.read_bytes(),
        app.state.core.db,
        app.state.core.auth,
        app.state.core.context,
        settings.clock,
    )
    snapshot = reopened.list(actor, authority.coreId, authority.homeId)
    assert snapshot.events[0].eventId == EVENT


def test_acknowledgement_requires_exact_revision_and_verified_readback(server):
    _app, client, _settings, _clock = server
    pair, actor, _authority, root = _seed(server)
    before = client.get(root, headers=auth(pair)).json()
    event = before["events"][0]
    command = {
        "schemaVersion": 1,
        "requestId": REQUEST,
        "expectedRepositoryRevision": before["repositoryRevision"],
        "expectedEventRevision": event["eventRevision"],
    }
    receipt = client.post(
        f"{root}/{EVENT}/acknowledgements", headers=auth(pair), json=command
    )
    assert receipt.status_code == 200
    value = receipt.json()
    assert value["requestId"] == REQUEST
    assert value["accountId"] == actor.id
    assert value["sessionFamilyId"] == actor.family_id
    assert value["acknowledged"] is True
    assert client.post(
        f"{root}/{EVENT}/acknowledgements", headers=auth(pair), json=command
    ).json() == value

    after = client.get(root, headers=auth(pair)).json()
    assert after["repositoryRevision"] == value["repositoryRevision"]
    assert after["events"][0]["eventRevision"] == value["eventRevision"]
    assert after["events"][0]["acknowledged"] is True


def test_scope_revision_session_and_storage_tamper_fail_closed(server):
    app, client, _settings, _clock = server
    pair, _actor, _authority, root = _seed(server)
    before = client.get(root, headers=auth(pair)).json()
    wrong = client.post(
        f"{root}/{EVENT}/acknowledgements",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": REQUEST,
            "expectedRepositoryRevision": before["repositoryRevision"] + 1,
            "expectedEventRevision": 1,
        },
    )
    assert (wrong.status_code, wrong.json()["error"]["code"]) == (
        409,
        "revision_conflict",
    )
    assert client.get(root.replace(app.state.core.context.homeId, "f" * 32), headers=auth(pair)).status_code == 404

    second = client.post(
        "/api/v1/auth/login",
        json={
            "username": "admin",
            "password": "Synthetic new password 2026",
            "deviceName": "Second tablet",
        },
    ).json()
    replay = client.post(
        f"{root}/{EVENT}/acknowledgements",
        headers=auth(second),
        json={
            "schemaVersion": 1,
            "requestId": REQUEST,
            "expectedRepositoryRevision": before["repositoryRevision"],
            "expectedEventRevision": 1,
        },
    )
    assert replay.status_code == 409

    with sqlite3.connect(app.state.core.sound_events.path) as connection:
        connection.execute(
            "UPDATE sound_events SET evidence_digest=? WHERE event_id=?",
            ("b" * 64, EVENT),
        )
    failed = client.get(root, headers=auth(pair))
    assert (failed.status_code, failed.json()["error"]["code"]) == (
        503,
        "sound_event_integrity_failed",
    )
