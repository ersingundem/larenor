import copy
import sqlite3

import pytest
from conftest import auth, ready
from fastapi.testclient import TestClient
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from test_f50_room_comfort import climate, occupancy, policy, weather


def _scope(value, core_id, home_id):
    result = copy.deepcopy(value)

    def visit(item):
        if isinstance(item, dict):
            if "coreId" in item:
                item["coreId"] = core_id
            if "homeId" in item:
                item["homeId"] = home_id
            for nested in item.values():
                visit(nested)
        elif isinstance(item, list):
            for nested in item:
                visit(nested)

    visit(result)
    return result


def _publish_body(app, now_ms):
    context = app.state.core.context
    policy_value = _scope(
        policy().model_dump(mode="json"), context.coreId, context.homeId
    )
    room = policy_value["rooms"][0]
    return {
        "schemaVersion": 1,
        "expectedHomeRevision": 1,
        "policy": policy_value,
        "climate": [
            _scope(
                climate(temperature=19_000, observed=now_ms).model_dump(
                    mode="json"
                ),
                context.coreId,
                context.homeId,
            )
        ],
        "weather": _scope(
            weather(observed=now_ms).model_dump(mode="json"),
            context.coreId,
            context.homeId,
        ),
        "occupancy": [
            _scope(
                occupancy(observed=now_ms).model_dump(mode="json"),
                context.coreId,
                context.homeId,
            )
        ],
        "overrides": [],
        "readbacks": [
            {
                "schemaVersion": 1,
                "coreId": context.coreId,
                "homeId": context.homeId,
                "roomId": room["roomId"],
                "device": room["hvac"],
                "stateRevision": 1,
                "state": "off",
                "observedAtMs": now_ms,
            },
            {
                "schemaVersion": 1,
                "coreId": context.coreId,
                "homeId": context.homeId,
                "roomId": room["roomId"],
                "device": room["window"],
                "stateRevision": 1,
                "state": "closed",
                "observedAtMs": now_ms,
            },
        ],
    }


def _plan_and_preview(app, client, headers, clock, request_id):
    context = app.state.core.context
    root = f"/api/v1/room-comfort/{context.coreId}/{context.homeId}"
    plan = client.put(
        root + "/plan",
        headers=headers,
        json=_publish_body(app, int(clock.now * 1000)),
    ).json()["plan"]
    preview = client.post(
        root + "/previews",
        headers=headers,
        json={
            "schemaVersion": 1,
            "requestId": request_id,
            "expectedPlanId": plan["planId"],
            "expectedHomeRevision": plan["homeRevision"],
            "expectedPolicyRevision": plan["policyRevision"],
        },
    ).json()["preview"]
    return root, plan, preview, {
        "schemaVersion": 1,
        "expectedPlanId": plan["planId"],
        "expectedPolicyRevision": plan["policyRevision"],
        "confirmToken": preview["confirmToken"],
    }


def test_authenticated_plan_preview_confirm_is_persistent_and_no_replay(server):
    app, client, settings, clock = server
    pair = ready(server)
    headers = auth(pair)
    context = app.state.core.context
    root = f"/api/v1/room-comfort/{context.coreId}/{context.homeId}"

    published = client.put(
        root + "/plan",
        headers=headers,
        json=_publish_body(app, int(clock.now * 1000)),
    )
    assert published.status_code == 200
    plan = published.json()["plan"]
    assert client.get(root + "/plan", headers=headers).json()["plan"] == plan

    request_id = "f" * 32
    previewed = client.post(
        root + "/previews",
        headers=headers,
        json={
            "schemaVersion": 1,
            "requestId": request_id,
            "expectedPlanId": plan["planId"],
            "expectedHomeRevision": plan["homeRevision"],
            "expectedPolicyRevision": plan["policyRevision"],
        },
    )
    assert previewed.status_code == 201
    preview = previewed.json()["preview"]
    assert preview["commandCount"] == 1

    stale = client.post(
        root + "/previews",
        headers=headers,
        json={
            "schemaVersion": 1,
            "requestId": "e" * 32,
            "expectedPlanId": plan["planId"],
            "expectedHomeRevision": plan["homeRevision"],
            "expectedPolicyRevision": plan["policyRevision"] + 1,
        },
    )
    assert stale.status_code == 409

    confirm_body = {
        "schemaVersion": 1,
        "expectedPlanId": plan["planId"],
        "expectedPolicyRevision": plan["policyRevision"],
        "confirmToken": preview["confirmToken"],
    }
    confirm_path = root + f"/previews/{preview['previewId']}/confirm"
    receipt = client.post(confirm_path, headers=headers, json=confirm_body)
    assert receipt.status_code == 201
    assert receipt.json()["receipt"]["status"] == "unknown"
    assert receipt.json()["receipt"]["results"][0]["code"] == "worker_ack_unknown"
    assert client.post(confirm_path, headers=headers, json=confirm_body).json() == receipt.json()

    with TestClient(create_app(settings)) as restarted:
        assert restarted.get(root + "/plan", headers=headers).json()["plan"] == plan
        assert restarted.post(confirm_path, headers=headers, json=confirm_body).json() == receipt.json()


def test_exact_worker_readback_marks_the_persistent_receipt_applied(server):
    app, client, _settings, clock = server
    pair = ready(server)
    headers = auth(pair)
    context = app.state.core.context
    root = f"/api/v1/room-comfort/{context.coreId}/{context.homeId}"

    def worker(command):
        return {
            "schemaVersion": 1,
            "commandId": command.commandId,
            "roomId": command.roomId,
            "device": command.device.model_dump(mode="json"),
            "stateRevision": command.expectedStateRevision + 1,
            "state": command.desiredState,
            "observedAtMs": int(clock.now * 1000),
        }

    app.state.core.room_comfort.worker = worker
    plan = client.put(
        root + "/plan",
        headers=headers,
        json=_publish_body(app, int(clock.now * 1000)),
    ).json()["plan"]
    preview = client.post(
        root + "/previews",
        headers=headers,
        json={
            "schemaVersion": 1,
            "requestId": "a" * 32,
            "expectedPlanId": plan["planId"],
            "expectedHomeRevision": plan["homeRevision"],
            "expectedPolicyRevision": plan["policyRevision"],
        },
    ).json()["preview"]
    receipt = client.post(
        root + f"/previews/{preview['previewId']}/confirm",
        headers=headers,
        json={
            "schemaVersion": 1,
            "expectedPlanId": plan["planId"],
            "expectedPolicyRevision": plan["policyRevision"],
            "confirmToken": preview["confirmToken"],
        },
    ).json()["receipt"]

    assert receipt["status"] == "applied"
    assert receipt["results"][0]["code"] == "applied"
    assert receipt["results"][0]["readback"]["state"] == "heat"


def test_duplicate_device_readback_is_rejected_before_plan_is_published(server):
    app, client, _settings, clock = server
    pair = ready(server)
    context = app.state.core.context
    root = f"/api/v1/room-comfort/{context.coreId}/{context.homeId}"
    body = _publish_body(app, int(clock.now * 1000))
    body["readbacks"].append(copy.deepcopy(body["readbacks"][0]))

    response = client.put(root + "/plan", headers=auth(pair), json=body)

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "revision_conflict"
    assert client.get(root + "/plan", headers=auth(pair)).status_code == 404


def test_storage_tamper_and_non_admin_access_fail_closed(server):
    app, client, settings, clock = server
    pair = ready(server)
    context = app.state.core.context
    root = f"/api/v1/room-comfort/{context.coreId}/{context.homeId}"
    published = client.put(
        root + "/plan",
        headers=auth(pair),
        json=_publish_body(app, int(clock.now * 1000)),
    )
    assert published.status_code == 200
    assert client.get(root + "/plan").status_code == 401

    with sqlite3.connect(settings.database_file) as connection:
        connection.execute(
            "UPDATE room_comfort_plans SET plan_json='{}' WHERE id=?",
            (published.json()["plan"]["planId"],),
        )
    with pytest.raises(StartupError, match="invalid_room_comfort_storage"):
        create_app(settings)


def test_dispatch_is_reserved_before_io_without_sqlite_lock_and_uses_post_io_time(
    server,
):
    app, client, settings, clock = server
    headers = auth(ready(server))
    root, _plan, preview, confirm = _plan_and_preview(
        app, client, headers, clock, "1" * 32
    )
    calls = []

    def worker(command):
        # BEGIN IMMEDIATE would fail here if confirm retained its reservation
        # transaction across provider I/O.
        with sqlite3.connect(settings.database_file, timeout=0.1) as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.rollback()
        clock.now += 1
        calls.append(command.commandId)
        return {
            "schemaVersion": 1,
            "commandId": command.commandId,
            "roomId": command.roomId,
            "device": command.device.model_dump(mode="json"),
            "stateRevision": command.expectedStateRevision + 1,
            "state": command.desiredState,
            "observedAtMs": int(clock.now * 1000),
        }

    app.state.core.room_comfort.worker = worker
    response = client.post(
        root + f"/previews/{preview['previewId']}/confirm",
        headers=headers,
        json=confirm,
    )

    assert response.status_code == 201
    assert response.json()["receipt"]["status"] == "applied"
    assert len(calls) == 1


def test_restart_style_dispatching_record_is_never_resent(server):
    app, client, _settings, clock = server
    headers = auth(ready(server))
    root, _plan, preview, confirm = _plan_and_preview(
        app, client, headers, clock, "2" * 32
    )
    service = app.state.core.room_comfort
    calls = []

    def worker(command):
        calls.append(command.commandId)
        return {
            "schemaVersion": 1,
            "commandId": command.commandId,
            "roomId": command.roomId,
            "device": command.device.model_dump(mode="json"),
            "stateRevision": command.expectedStateRevision + 1,
            "state": command.desiredState,
            "observedAtMs": int(clock.now * 1000),
        }

    original = service._complete_dispatch
    service.worker = worker
    service._complete_dispatch = lambda *_args: (_ for _ in ()).throw(
        RuntimeError("synthetic crash after provider I/O")
    )
    crashed = client.post(
        root + f"/previews/{preview['previewId']}/confirm",
        headers=headers,
        json=confirm,
    )
    assert crashed.status_code == 503
    service._complete_dispatch = original

    recovered = client.post(
        root + f"/previews/{preview['previewId']}/confirm",
        headers=headers,
        json=confirm,
    )

    assert len(calls) == 1
    assert recovered.status_code == 201
    assert recovered.json()["receipt"]["status"] == "unknown"
    assert recovered.json()["receipt"]["results"][0]["code"] == "worker_ack_unknown"


def test_admin_provisions_revision_bound_authenticated_ha_source(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    headers = auth(pair)
    context = app.state.core.context
    resource_root = (
        f"/api/v1/admin/home-resources/{context.coreId}/{context.homeId}"
    )
    room = client.post(
        resource_root,
        headers=headers,
        json={"kind": "room", "label": "Living room", "order": 0},
    ).json()["record"]
    area = client.post(
        resource_root,
        headers=headers,
        json={"kind": "resource", "label": "Downstairs", "order": 0},
    ).json()["record"]
    service = client.post(
        "/api/v1/admin/services",
        headers=headers,
        json={
            "name": "Home Assistant",
            "kind": "home_assistant",
            "baseUrl": "http://127.0.0.1:8123",
            "credentials": {"token": "synthetic-secret"},
        },
    ).json()["service"]
    root = f"/api/v1/room-comfort/{context.coreId}/{context.homeId}"
    payload = {
        "schemaVersion": 1,
        "expectedRevision": None,
        "serviceId": service["id"],
        "expectedServiceRevision": 1,
        "weatherEntityId": "weather.home",
        "aqiEntityId": "sensor.outdoor_aqi",
        "targetTemperatureMilliC": 22000,
        "temperatureToleranceMilliC": 1000,
        "humidityHighPermille": 700,
        "co2HighPpm": 1000,
        "vocHighPpb": 500,
        "outdoorAqiLimit": 100,
        "freezeThresholdMilliC": 3000,
        "indoorMaxAgeMs": 60000,
        "outdoorMaxAgeMs": 120000,
        "occupancyMaxAgeMs": 60000,
        "previewTtlMs": 30000,
        "rooms": [{
            "roomId": room["ref"]["id"],
            "roomRevision": room["revision"],
            "areaId": area["ref"]["id"],
            "areaRevision": area["revision"],
            "climateEntityId": "climate.living_room",
            "windowEntityId": "cover.living_room_window",
            "temperatureEntityId": "sensor.living_temperature",
            "humidityEntityId": "sensor.living_humidity",
            "co2EntityId": "sensor.living_co2",
            "vocEntityId": "sensor.living_voc",
            "smokeEntityId": "binary_sensor.living_smoke",
            "occupancyEntityId": "binary_sensor.living_occupancy",
        }],
    }

    unverified = client.put(
        root + "/configuration", headers=headers, json=payload
    )
    assert unverified.status_code == 409
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    app.state.core.services.record_verification(
        actor, service["id"], 1, state="authenticated", version="2026.9"
    )
    # This test isolates storage/CAS behavior. Real registry/state preflight is
    # exercised through the normal Core network boundary in the F50 loopback
    # acceptance test.
    app.state.core.room_comfort.source_store._preflight = None
    saved = client.put(root + "/configuration", headers=headers, json=payload)

    assert saved.status_code == 200, saved.text
    configuration = saved.json()["configuration"]
    assert configuration["revision"] == 1
    assert configuration["serviceRevision"] == 1
    assert "expectedRevision" not in configuration
    assert "synthetic-secret" not in saved.text
    assert client.get(
        root + "/configuration", headers=headers
    ).json()["configuration"] == configuration
    forged = client.put(
        root + "/plan",
        headers=headers,
        json=_publish_body(app, int(_clock.now * 1000)),
    )
    assert forged.status_code == 409
    stale = client.put(root + "/configuration", headers=headers, json=payload)
    assert stale.status_code == 409
