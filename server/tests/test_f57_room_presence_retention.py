"""F57 authenticated bounded calibration receipt retention."""

from fastapi.testclient import TestClient
from http.server import ThreadingHTTPServer
import pytest
from threading import Thread

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.errors import StartupError
import larenor_server.room_presence.repository as repository_module
from test_f57_room_presence_http import DEVICE, ROOM, _provision, _scope_body
from test_f57_mqtt_room_normal_core import MqttRoomHomeAssistant


def _setup(server):
    app, client, settings, clock = server
    actor = ready(server)
    _provision(app, actor)
    context = app.state.core.context
    root = f"/api/v1/room-presence/{context.coreId}/{context.homeId}"
    authority = client.post(
        root + "/scope", headers=auth(actor), json=_scope_body(41)
    ).json()
    return app, client, settings, clock, actor, root, authority


def _calibrate(client, actor, root, authority, revision, request_id):
    preview = client.post(
        root + f"/devices/{DEVICE}/calibration/preview",
        headers=auth(actor),
        json={
            "schemaVersion": 1,
            "authority": authority,
            "deviceId": DEVICE,
            "expectedDeviceRevision": 9,
            "expectedModelRevision": 4,
            "roomId": ROOM,
            "expectedRoomRevision": 13,
            "expectedPolicyRevision": 7,
            "expectedConsentRevision": 11,
            "expectedCalibrationRevision": revision,
            "requestId": request_id,
        },
    )
    assert preview.status_code == 200, preview.text
    confirmed = client.post(
        root + f"/calibrations/{request_id}/confirm",
        headers=auth(actor), json=preview.json(),
    )
    assert confirmed.status_code == 200, confirmed.text
    return preview.json(), confirmed.json()


def _refresh(client, actor):
    response = client.post(
        "/api/v1/auth/refresh", json={"refreshToken": actor["refreshToken"]}
    )
    assert response.status_code == 200, response.text
    return response.json()


def test_default_cap_reclaims_old_history_after_restart_and_preserves_replay(server):
    app, client, settings, clock, actor, root, authority = _setup(server)
    app.state.core.auth.rate_limit = lambda *_args, **_kwargs: None
    history = []
    for index in range(repository_module.MAX_RECEIPTS):
        request_id = f"{index + 1:032x}"
        history.append(
            _calibrate(client, actor, root, authority, index + 1, request_id)
        )
    clock.now += 24 * 60 * 60 + 121

    with TestClient(create_app(settings)) as restarted:
        actor = _refresh(restarted, actor)
        current_authority = restarted.post(
            root + "/scope", headers=auth(actor), json=_scope_body(41)
        ).json()
        newest = _calibrate(
            restarted,
            actor,
            root,
            current_authority,
            repository_module.MAX_RECEIPTS + 1,
            "f" * 32,
        )
        replay = restarted.post(
            root + f"/calibrations/{history[-1][0]['requestId']}/confirm",
            headers=auth(actor), json=history[-1][0],
        )
        assert replay.status_code == 200
        assert replay.json() == history[-1][1]
        assert restarted.post(
            root + f"/calibrations/{history[0][0]['requestId']}/confirm",
            headers=auth(actor), json=history[0][0],
        ).status_code == 409
        readback = restarted.post(
            root + f"/devices/{DEVICE}/readback",
            headers=auth(actor),
            json={"schemaVersion": 1, "authority": current_authority},
        )
        assert readback.json()["calibrationRevision"] == 258
        assert newest[1]["observedCalibrationRevision"] == 258
        state = restarted.app.state.core.room_presence.repository._state
        assert len(state["receipts"]) == 33
        assert len(state["previews"]) == 33


def test_uncertain_receipts_remain_capacity_blocking_and_replay_without_reapply(
    server, monkeypatch
):
    monkeypatch.setattr(repository_module, "MAX_RECEIPTS", 3)
    monkeypatch.setattr(repository_module, "RETAINED_CALIBRATION_RECEIPTS", 0)
    app, client, _settings, clock, actor, root, authority = _setup(server)
    values = [
        _calibrate(client, actor, root, authority, index + 1, f"{index + 1:x}" * 32)
        for index in range(3)
    ]
    repository = app.state.core.room_presence.repository
    with repository._lock:
        repository._sync()
        before = repository._state["revision"]
        for preview, _receipt in values:
            stored = repository._state["receipts"][preview["requestId"]]
            stored["status"] = "uncertain"
            stored["observedCalibrationRevision"] = None
        repository._state["revision"] = before + 1
        repository._persist(before)
    clock.now += 24 * 60 * 60 + 121
    actor = _refresh(client, actor)
    authority = client.post(
        root + "/scope", headers=auth(actor), json=_scope_body(41)
    ).json()

    blocked = client.post(
        root + f"/devices/{DEVICE}/calibration/preview",
        headers=auth(actor),
        json={
            "schemaVersion": 1, "authority": authority, "deviceId": DEVICE,
            "expectedDeviceRevision": 9, "expectedModelRevision": 4,
            "roomId": ROOM, "expectedRoomRevision": 13,
            "expectedPolicyRevision": 7, "expectedConsentRevision": 11,
            "expectedCalibrationRevision": 4, "requestId": "e" * 32,
        },
    )
    assert blocked.status_code == 409
    replay = client.post(
        root + f"/calibrations/{values[0][0]['requestId']}/confirm",
        headers=auth(actor), json=values[0][0],
    )
    assert replay.status_code == 200
    assert replay.json()["status"] == "uncertain"
    assert repository._state["devices"][DEVICE]["calibrationRevision"] == 4
    assert len(repository._state["receipts"]) == 3


def test_24_hour_boundary_is_inclusive_and_current_calibration_stays_protected(
    server, monkeypatch
):
    monkeypatch.setattr(repository_module, "MAX_RECEIPTS", 2)
    monkeypatch.setattr(repository_module, "RETAINED_CALIBRATION_RECEIPTS", 0)
    app, client, _settings, clock, actor, root, authority = _setup(server)
    values = [
        _calibrate(client, actor, root, authority, index + 1, f"{index + 7:x}" * 32)
        for index in range(2)
    ]
    first_recorded = app.state.core.room_presence.repository._state[
        "receiptTimes"
    ][values[0][0]["requestId"]]
    clock.now = (
        first_recorded + repository_module.CALIBRATION_REPLAY_WINDOW_MS
    ) / 1000
    actor = _refresh(client, actor)
    authority = client.post(
        root + "/scope", headers=auth(actor), json=_scope_body(41)
    ).json()
    body = {
        "schemaVersion": 1, "authority": authority, "deviceId": DEVICE,
        "expectedDeviceRevision": 9, "expectedModelRevision": 4,
        "roomId": ROOM, "expectedRoomRevision": 13,
        "expectedPolicyRevision": 7, "expectedConsentRevision": 11,
        "expectedCalibrationRevision": 3, "requestId": "d" * 32,
    }
    assert client.post(
        root + f"/devices/{DEVICE}/calibration/preview",
        headers=auth(actor), json=body,
    ).status_code == 409

    clock.now += 0.001
    allowed = client.post(
        root + f"/devices/{DEVICE}/calibration/preview",
        headers=auth(actor), json=body,
    )
    assert allowed.status_code == 200, allowed.text
    state = app.state.core.room_presence.repository._state
    assert values[0][0]["requestId"] not in state["receipts"]
    assert values[1][0]["requestId"] in state["receipts"]


def test_authenticated_parent_mismatch_and_ciphertext_tamper_fail_closed(server):
    app, client, settings, _clock, actor, root, authority = _setup(server)
    preview, _receipt = _calibrate(
        client, actor, root, authority, 1, "a" * 32
    )
    repository = app.state.core.room_presence.repository
    with repository._lock:
        repository._sync()
        before = repository._state["revision"]
        repository._state["receipts"][preview["requestId"]]["roomId"] = "b" * 32
        repository._state["revision"] = before + 1
        repository._persist(before)
    with pytest.raises(StartupError, match="room_presence_storage_invalid"):
        create_app(settings)


def test_legacy_orphan_receipt_gets_conservative_migration_time(server, monkeypatch):
    monkeypatch.setattr(repository_module, "MAX_RECEIPTS", 2)
    monkeypatch.setattr(repository_module, "RETAINED_CALIBRATION_RECEIPTS", 0)
    app, client, settings, clock, actor, root, authority = _setup(server)
    values = [
        _calibrate(client, actor, root, authority, index + 1, f"{index + 4:x}" * 32)
        for index in range(2)
    ]
    repository = app.state.core.room_presence.repository
    with repository._lock:
        repository._sync()
        before = repository._state["revision"]
        repository._state["schemaVersion"] = 1
        repository._state.pop("receiptTimes")
        repository._state["previews"].pop(values[0][0]["requestId"])
        repository._state["revision"] = before + 1
        repository._persist(before)

    with TestClient(create_app(settings)) as restarted:
        migrated = restarted.app.state.core.room_presence.repository._state
        assert migrated["schemaVersion"] == 2
        assert set(migrated["receiptTimes"]) == {
            value[0]["requestId"] for value in values
        }
        assert migrated["receiptTimes"][values[0][0]["requestId"]] == int(
            clock.now * 1000
        )
        actor = _refresh(restarted, actor)
        current_authority = restarted.post(
            root + "/scope", headers=auth(actor), json=_scope_body(41)
        ).json()
        body = {
            "schemaVersion": 1, "authority": current_authority,
            "deviceId": DEVICE, "expectedDeviceRevision": 9,
            "expectedModelRevision": 4, "roomId": ROOM,
            "expectedRoomRevision": 13, "expectedPolicyRevision": 7,
            "expectedConsentRevision": 11, "expectedCalibrationRevision": 3,
            "requestId": "a" * 32,
        }
        assert restarted.post(
            root + f"/devices/{DEVICE}/calibration/preview",
            headers=auth(actor), json=body,
        ).status_code == 409
        clock.now += 24 * 60 * 60 + 0.001
        actor = _refresh(restarted, actor)
        current_authority = restarted.post(
            root + "/scope", headers=auth(actor), json=_scope_body(41)
        ).json()
        body["authority"] = current_authority
        allowed = restarted.post(
            root + f"/devices/{DEVICE}/calibration/preview",
            headers=auth(actor), json=body,
        )
        assert allowed.status_code == 200, allowed.text
        assert values[0][0]["requestId"] not in (
            restarted.app.state.core.room_presence.repository._state["receipts"]
        )


def test_v1_delayed_confirmation_migration_never_shortens_24_hour_replay(
    server, monkeypatch
):
    monkeypatch.setattr(repository_module, "MAX_RECEIPTS", 2)
    monkeypatch.setattr(repository_module, "RETAINED_CALIBRATION_RECEIPTS", 0)
    app, client, settings, clock, actor, root, authority = _setup(server)
    first = _calibrate(client, actor, root, authority, 1, "1" * 32)
    clock.now += 119
    second = _calibrate(client, actor, root, authority, 2, "2" * 32)
    repository = app.state.core.room_presence.repository
    with repository._lock:
        repository._sync()
        before = repository._state["revision"]
        repository._state["schemaVersion"] = 1
        repository._state.pop("receiptTimes")
        repository._state["revision"] = before + 1
        repository._persist(before)
    migration_ms = int(clock.now * 1000)

    with TestClient(create_app(settings)) as restarted:
        migrated = restarted.app.state.core.room_presence.repository._state
        assert migrated["receiptTimes"] == {
            first[0]["requestId"]: migration_ms,
            second[0]["requestId"]: migration_ms,
        }
        clock.now = (
            migration_ms + repository_module.CALIBRATION_REPLAY_WINDOW_MS
        ) / 1000
        actor = _refresh(restarted, actor)
        current_authority = restarted.post(
            root + "/scope", headers=auth(actor), json=_scope_body(41)
        ).json()
        body = {
            "schemaVersion": 1, "authority": current_authority,
            "deviceId": DEVICE, "expectedDeviceRevision": 9,
            "expectedModelRevision": 4, "roomId": ROOM,
            "expectedRoomRevision": 13, "expectedPolicyRevision": 7,
            "expectedConsentRevision": 11, "expectedCalibrationRevision": 3,
            "requestId": "3" * 32,
        }
        assert restarted.post(
            root + f"/devices/{DEVICE}/calibration/preview",
            headers=auth(actor), json=body,
        ).status_code == 409
        clock.now += 0.001
        allowed = restarted.post(
            root + f"/devices/{DEVICE}/calibration/preview",
            headers=auth(actor), json=body,
        )
        assert allowed.status_code == 200, allowed.text


def test_recent_window_counts_32_terminals_separately_from_uncertain(server):
    app, client, _settings, clock, actor, _root, authority = _setup(server)
    app.state.core.auth.rate_limit = lambda *_args, **_kwargs: None
    root = (
        f"/api/v1/room-presence/{app.state.core.context.coreId}/"
        f"{app.state.core.context.homeId}"
    )
    values = [
        _calibrate(client, actor, root, authority, index + 1, f"{index + 1:032x}")
        for index in range(70)
    ]
    repository = app.state.core.room_presence.repository
    with repository._lock:
        repository._sync()
        before = repository._state["revision"]
        uncertain = {
            value[0]["requestId"] for value in values[:30]
        }
        for request_id in uncertain:
            receipt = repository._state["receipts"][request_id]
            receipt["status"] = "uncertain"
            receipt["observedCalibrationRevision"] = None
        repository._state["revision"] = before + 1
        repository._persist(before)
    clock.now += 24 * 60 * 60 + 0.001
    candidates = repository._calibration_retention_candidates(
        repository._state, int(clock.now * 1000)
    )
    expected_candidates = {
        value[0]["requestId"] for value in values[30:38]
    }
    assert candidates == expected_candidates
    assert uncertain.isdisjoint(candidates)
    protected_terminals = {
        value[0]["requestId"] for value in values[38:]
    }
    assert len(protected_terminals) == 32
    assert protected_terminals.isdisjoint(candidates)



def test_ciphertext_tamper_fails_closed(server):
    app, _client, settings, _clock, actor, _root, _authority = _setup(server)
    with app.state.core.db.transaction() as connection:
        row = connection.execute(
            "SELECT ciphertext FROM room_presence_state WHERE singleton=1"
        ).fetchone()
        changed = bytearray(row["ciphertext"])
        changed[-1] ^= 1
        connection.execute(
            "UPDATE room_presence_state SET ciphertext=? WHERE singleton=1",
            (bytes(changed),),
        )
    with pytest.raises(StartupError, match="room_presence_storage_invalid"):
        create_app(settings)


def test_v1_migration_rejects_invalid_containers_before_timestamp_conversion(server):
    app, _client, settings, _clock, _actor, _root, _authority = _setup(server)
    repository = app.state.core.room_presence.repository
    with repository._lock:
        repository._sync()
        before = repository._state["revision"]
        repository._state["schemaVersion"] = 1
        repository._state.pop("receiptTimes")
        repository._state["previews"] = []
        repository._state["revision"] = before + 1
        repository._persist(before)
    with pytest.raises(StartupError, match="room_presence_storage_invalid"):
        create_app(settings)


def test_retention_write_failure_restores_all_candidates(server, monkeypatch):
    monkeypatch.setattr(repository_module, "MAX_RECEIPTS", 2)
    monkeypatch.setattr(repository_module, "RETAINED_CALIBRATION_RECEIPTS", 0)
    app, client, _settings, clock, actor, root, authority = _setup(server)
    values = [
        _calibrate(client, actor, root, authority, index + 1, f"{index + 1:x}" * 32)
        for index in range(2)
    ]
    clock.now += 24 * 60 * 60 + 121
    actor = _refresh(client, actor)
    authority = client.post(
        root + "/scope", headers=auth(actor), json=_scope_body(41)
    ).json()
    repository = app.state.core.room_presence.repository
    original = repository._persist

    def fail_write(_previous_revision):
        raise RuntimeError("controlled_write_failure")

    repository._persist = fail_write
    try:
        failed = client.post(
            root + f"/devices/{DEVICE}/calibration/preview",
            headers=auth(actor),
            json={
                "schemaVersion": 1, "authority": authority, "deviceId": DEVICE,
                "expectedDeviceRevision": 9, "expectedModelRevision": 4,
                "roomId": ROOM, "expectedRoomRevision": 13,
                "expectedPolicyRevision": 7, "expectedConsentRevision": 11,
                "expectedCalibrationRevision": 3, "requestId": "d" * 32,
            },
        )
        assert failed.status_code == 503
    finally:
        repository._persist = original
    repository._sync()
    assert set(repository._state["receipts"]) == {
        value[0]["requestId"] for value in values
    }
    assert set(repository._state["previews"]) == {
        value[0]["requestId"] for value in values
    }


def test_actual_mqtt_room_provider_is_not_recalled_by_confirm_or_replay(server):
    app, client, _settings, clock = server
    upstream = ThreadingHTTPServer(("127.0.0.1", 0), MqttRoomHomeAssistant)
    thread = Thread(target=upstream.serve_forever, daemon=True)
    thread.start()
    try:
        MqttRoomHomeAssistant.observed_ms = int(clock.now * 1000)
        MqttRoomHomeAssistant.entity = "sensor.owner_room"
        MqttRoomHomeAssistant.unique_id = "retention-private-device"
        MqttRoomHomeAssistant.name = "Owner room"
        MqttRoomHomeAssistant.room = "living"
        MqttRoomHomeAssistant.after_registry = None
        MqttRoomHomeAssistant.requests = []
        actor = ready(server)
        headers = auth(actor)
        context = app.state.core.context
        resources = f"/api/v1/admin/home-resources/{context.coreId}/{context.homeId}"
        room = client.post(resources, headers=headers, json={
            "kind": "room", "label": "Living room", "order": 0,
        }).json()["record"]
        service = client.post("/api/v1/admin/services", headers=headers, json={
            "name": "Home Assistant", "kind": "home_assistant",
            "baseUrl": f"http://127.0.0.1:{upstream.server_port}",
            "credentials": {"token": "private-ha-token"},
        }).json()["service"]
        principal = app.state.core.auth.authenticate(actor["accessToken"])
        app.state.core.services.record_verification(
            principal, service["id"], 1,
            state="authenticated", version="2026.9",
        )
        root = f"/api/v1/room-presence/{context.coreId}/{context.homeId}"
        entity = client.get(
            root + f"/configuration/entities/{service['id']}/1",
            headers=headers,
        ).json()["entities"][0]
        configured = client.put(root + "/configuration", headers=headers, json={
            "schemaVersion": 1, "expectedRevision": None,
            "serviceId": service["id"], "expectedServiceRevision": 1,
            "entityId": entity["entityId"], "candidateId": entity["candidateId"],
            "roomId": room["ref"]["id"],
            "expectedRoomRevision": room["revision"],
            "maxSignalAgeMs": 30_000, "consent": True,
        })
        assert configured.status_code == 200, configured.text
        authority = client.post(
            root + "/scope", headers=headers, json=_scope_body(43)
        ).json()
        observed = client.post(
            root + "/devices/query", headers=headers,
            json={"schemaVersion": 1, "authority": authority},
        ).json()["devices"][0]
        requests_before = list(MqttRoomHomeAssistant.requests)
        request_id = "c" * 32
        preview = client.post(
            root + f"/devices/{observed['deviceId']}/calibration/preview",
            headers=headers,
            json={
                "schemaVersion": 1, "authority": authority,
                "deviceId": observed["deviceId"],
                "expectedDeviceRevision": observed["deviceRevision"],
                "expectedModelRevision": observed["modelRevision"],
                "roomId": observed["configuredRoomId"],
                "expectedRoomRevision": observed["configuredRoomRevision"],
                "expectedPolicyRevision": observed["policyRevision"],
                "expectedConsentRevision": observed["consentRevision"],
                "expectedCalibrationRevision": observed["calibrationRevision"],
                "requestId": request_id,
            },
        )
        assert preview.status_code == 200, preview.text
        first = client.post(
            root + f"/calibrations/{request_id}/confirm",
            headers=headers, json=preview.json(),
        )
        assert first.status_code == 200, first.text
        replay = client.post(
            root + f"/calibrations/{request_id}/confirm",
            headers=headers, json=preview.json(),
        )
        assert replay.json() == first.json()
        assert MqttRoomHomeAssistant.requests == requests_before
    finally:
        upstream.shutdown()
        upstream.server_close()
        thread.join(timeout=2)
