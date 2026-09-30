import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.errors import ApiError
from support.f41_frigate_fixture import provision
from support.f45_sound_fixture import SoundFixture


@pytest.fixture
def frigate():
    value = SoundFixture()
    yield value
    value.close()
    assert value.errors == []


def configured(server, frigate):
    app, client, _settings, _clock = server
    actor = ready(server)
    _search, _setup, _body, cameras, _services = provision(
        client, app.state.core, actor, frigate
    )
    scope = app.state.core.context
    room = client.post(
        f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}",
        headers=auth(actor),
        json={"kind": "room", "label": "Entry", "order": 0},
    ).json()["record"]
    root = f"/api/v1/sound-events/{scope.coreId}/{scope.homeId}"
    setup = client.get(root + "/source", headers=auth(actor))
    assert setup.status_code == 200, setup.text
    value = setup.json()
    front = next(item for item in value["cameras"] if item["label"] == "Front door")
    body = {
        "schemaVersion": 1,
        "expectedRevision": None,
        "cameraResourceId": front["id"],
        "expectedCameraRevision": front["revision"],
        "roomId": room["ref"]["id"],
        "expectedRoomRevision": room["revision"],
        "labels": {"bark": ["bark"], "noise": ["fire_alarm"]},
        "consentGranted": True,
        "retentionSeconds": 60,
    }
    response = client.put(root + "/source", headers=auth(actor), json=body)
    assert response.status_code == 200, response.text
    return actor, root, body


def test_normal_core_reads_exact_reviews_persists_and_never_writes_provider(server, frigate):
    app, client, settings, _clock = server
    actor, root, _body = configured(server, frigate)
    before = client.get(root, headers=auth(actor)).json()
    assert before["sourceStatus"]["state"] == "unavailable"

    refreshed = client.post(root + "/source/refresh", headers=auth(actor))
    assert refreshed.status_code == 200, (refreshed.text, frigate.calls, frigate.errors)
    assert refreshed.json() == {
        "schemaVersion": 1,
        "configurationRevision": 1,
        "importedEvents": 2,
        "reviewedRecords": 1,
    }
    snapshot = client.get(root, headers=auth(actor)).json()
    assert snapshot["sourceStatus"]["state"] == "ready"
    assert snapshot["sourceStatus"]["silenceProven"] is False
    assert snapshot["sourceStatus"]["clipAvailable"] is False
    assert {item["className"] for item in snapshot["events"]} == {"bark", "noise"}
    assert all(item["automationVerified"] is False for item in snapshot["events"])
    assert frigate.token not in refreshed.text + client.get(root + "/source", headers=auth(actor)).text

    repeated = client.post(root + "/source/refresh", headers=auth(actor))
    assert repeated.status_code == 200 and repeated.json()["importedEvents"] == 0
    assert not any(method != "GET" for method, _path in frigate.calls)

    with TestClient(create_app(settings)) as restarted:
        setup = restarted.get(root + "/source", headers=auth(actor))
        assert setup.status_code == 200 and setup.json()["revision"] == 1
        persisted = restarted.get(root, headers=auth(actor)).json()
        assert len(persisted["events"]) == 2


def test_no_review_is_degraded_not_silence_and_expiry_is_purged(server, frigate):
    _app, client, _settings, clock = server
    actor, root, _body = configured(server, frigate)
    frigate.reviews.clear()
    response = client.post(root + "/source/refresh", headers=auth(actor))
    assert response.status_code == 200
    status = client.get(root, headers=auth(actor)).json()["sourceStatus"]
    assert status["state"] == "degraded" and status["lastObservationAtMs"] is None
    assert status["silenceProven"] is False

    frigate.reviews[:] = [frigate.review("1788609600-front", "front")]
    assert client.post(root + "/source/refresh", headers=auth(actor)).status_code == 200
    clock.now += 61
    frigate.reviews.clear()
    assert client.post(root + "/source/refresh", headers=auth(actor)).status_code == 200
    assert client.get(root, headers=auth(actor)).json()["events"] == []


def test_offline_consent_revoke_is_local_cas_and_hides_retained_history(server, frigate):
    _app, client, _settings, _clock = server
    actor, root, body = configured(server, frigate)
    assert client.post(root + "/source/refresh", headers=auth(actor)).status_code == 200
    assert len(client.get(root, headers=auth(actor)).json()["events"]) == 2

    frigate.available = False
    calls = len(frigate.calls)
    revoked = client.put(root + "/source", headers=auth(actor), json={
        **body, "expectedRevision": 1, "consentGranted": False,
    })
    assert revoked.status_code == 200, revoked.text
    assert revoked.json()["configuration"]["revision"] == 2
    assert revoked.json()["configuration"]["consentGranted"] is False
    assert revoked.json()["cameras"] == revoked.json()["rooms"] == []
    snapshot = client.get(root, headers=auth(actor))
    assert snapshot.status_code == 200, snapshot.text
    assert snapshot.json()["events"] == []
    assert snapshot.json()["sourceStatus"]["state"] == "unavailable"
    assert len(frigate.calls) == calls


def test_history_fails_closed_after_camera_permission_or_room_revision_drift(server, frigate):
    app, client, _settings, _clock = server
    actor, root, body = configured(server, frigate)
    assert client.post(root + "/source/refresh", headers=auth(actor)).status_code == 200

    frigate.allowed = ["back"]
    denied = client.get(root, headers=auth(actor))
    assert (denied.status_code, denied.json()["error"]["code"]) == (409, "revision_conflict")

    frigate.allowed = ["front", "back"]
    scope = app.state.core.context
    changed = client.patch(
        f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}/{body['roomId']}",
        headers=auth(actor),
        json={"expectedRevision": 1, "expectedAclRevision": 1,
              "label": "Renamed entry", "order": 0},
    )
    assert changed.status_code == 200, changed.text
    stale = client.get(root, headers=auth(actor))
    assert (stale.status_code, stale.json()["error"]["code"]) == (409, "revision_conflict")


def test_audio_capability_consent_cancel_and_session_drift_fail_closed(server, frigate):
    app, client, _settings, _clock = server
    frigate.audio_enabled = False
    actor = ready(server)
    _search, _setup, _body, _cameras, _services = provision(client, app.state.core, actor, frigate)
    scope = app.state.core.context
    room = client.post(
        f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}", headers=auth(actor),
        json={"kind": "room", "label": "Entry", "order": 0},
    ).json()["record"]
    root = f"/api/v1/sound-events/{scope.coreId}/{scope.homeId}"
    setup = client.get(root + "/source", headers=auth(actor)).json()
    camera = next(item for item in setup["cameras"] if item["label"] == "Front door")
    body = {"schemaVersion": 1, "expectedRevision": None,
            "cameraResourceId": camera["id"], "expectedCameraRevision": camera["revision"],
            "roomId": room["ref"]["id"], "expectedRoomRevision": room["revision"],
            "labels": {"bark": ["bark"], "noise": []}, "consentGranted": True,
            "retentionSeconds": 60}
    denied = client.put(root + "/source", headers=auth(actor), json=body)
    assert (denied.status_code, denied.json()["error"]["code"]) == (409, "camera_search_source_unavailable")

    frigate.audio_enabled = True
    assert client.put(root + "/source", headers=auth(actor), json=body).status_code == 200
    principal = app.state.core.auth.authenticate(actor["accessToken"])
    checks = 0

    def cancelled_after_provider_reads():
        nonlocal checks
        checks += 1
        return checks >= 4

    with pytest.raises(ApiError, match="revision_conflict"):
        app.state.core.sound_event_source.refresh(
            principal, scope.coreId, scope.homeId,
            cancelled=cancelled_after_provider_reads,
        )
    assert client.get(root, headers=auth(actor)).json()["events"] == []

    def revoke():
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE session_families SET revoked_at=? WHERE id=?",
                (1788609600.0, actor["sessionFamilyId"]),
            )

    frigate.during = revoke
    failed = client.post(root + "/source/refresh", headers=auth(actor))
    assert failed.status_code in {401, 409, 503}
    with app.state.core.sound_events._connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM sound_events").fetchone()[0] == 0


def test_public_frigate_read_lease_is_fixed_bounded_and_private(server, frigate):
    app, _client, _settings, _clock = server
    actor, _root, _body = configured(server, frigate)
    principal = app.state.core.auth.authenticate(actor["accessToken"])
    scope = app.state.core.context
    lease = app.state.core.camera_search_runtime.authorized_read(
        principal, scope.coreId, scope.homeId
    )
    assert lease.get_version() == "0.17.0-f45-v1"
    assert set(lease.camera_mapping.values()) == {"front", "back"}
    assert not hasattr(lease, "service") and not hasattr(lease, "token")
    with pytest.raises(ApiError, match="forbidden"):
        lease.get_json("/api/events")
    with pytest.raises(ApiError, match="invalid_request"):
        lease.get_json("/api/review", query={
            "cameras": "front", "after": "1788609000",
            "before": "1788609601", "limit": "65",
        })
