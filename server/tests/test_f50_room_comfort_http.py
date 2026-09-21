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
