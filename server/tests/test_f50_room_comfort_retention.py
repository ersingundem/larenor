import sqlite3

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.errors import ApiError, StartupError
from larenor_server.room_comfort import service as room_service
from larenor_server.room_comfort.service import MAX_PLANS
from test_f50_room_comfort_http import _publish_body


def _root(app):
    context = app.state.core.context
    return f"/api/v1/room-comfort/{context.coreId}/{context.homeId}"


def _publish(app, client, headers, clock):
    response = client.put(
        _root(app) + "/plan",
        headers=headers,
        json=_publish_body(app, int(clock.now * 1000)),
    )
    clock.now += 1
    return response


def _preview(app, client, headers, plan, request_number):
    return client.post(
        _root(app) + "/previews",
        headers=headers,
        json={
            "schemaVersion": 1,
            "requestId": f"{request_number:032x}",
            "expectedPlanId": plan["planId"],
            "expectedHomeRevision": plan["homeRevision"],
            "expectedPolicyRevision": plan["policyRevision"],
        },
    )


def _confirm(app, client, headers, plan, preview):
    body = {
        "schemaVersion": 1,
        "expectedPlanId": plan["planId"],
        "expectedPolicyRevision": plan["policyRevision"],
        "confirmToken": preview["confirmToken"],
    }
    path = _root(app) + f"/previews/{preview['previewId']}/confirm"
    return path, body, client.post(path, headers=headers, json=body)


def _applied_worker(clock):
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

    return worker


def test_normal_core_restart_recovers_after_more_than_maximum_plan_refreshes(server):
    app, client, settings, clock = server
    headers = auth(ready(server))
    context = app.state.core.context
    root = f"/api/v1/room-comfort/{context.coreId}/{context.homeId}"

    for _index in range(MAX_PLANS):
        response = client.put(
            root + "/plan",
            headers=headers,
            json=_publish_body(app, int(clock.now * 1000)),
        )
        assert response.status_code == 200
        clock.now += 1

    clock.now += 1
    with TestClient(create_app(settings)) as restarted:
        recovered = restarted.put(
            root + "/plan",
            headers=headers,
            json=_publish_body(restarted.app, int(clock.now * 1000)),
        )
        assert recovered.status_code == 200
        assert restarted.get(root + "/plan", headers=headers).json()["plan"] == (
            recovered.json()["plan"]
        )


def test_expired_unconfirmed_previews_release_capacity_without_replaying(server, monkeypatch):
    app, client, _settings, clock = server
    headers = auth(ready(server))
    monkeypatch.setattr(room_service, "MAX_PREVIEWS", 3)
    plan = _publish(app, client, headers, clock).json()["plan"]

    for request_number in range(1, 4):
        assert _preview(
            app, client, headers, plan, request_number
        ).status_code == 201
    assert _preview(app, client, headers, plan, 4).status_code == 429

    clock.now += 61
    recovered = _preview(app, client, headers, plan, 5)
    assert recovered.status_code == 201
    with sqlite3.connect(_settings.database_file) as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM room_comfort_previews"
        ).fetchone()[0] == 1


def test_recent_terminal_receipt_replays_exactly_while_expired_preview_is_pruned(
    server, monkeypatch
):
    app, client, _settings, clock = server
    headers = auth(ready(server))
    monkeypatch.setattr(room_service, "MAX_PREVIEWS", 2)
    plan = _publish(app, client, headers, clock).json()["plan"]
    app.state.core.room_comfort.worker = _applied_worker(clock)
    first = _preview(app, client, headers, plan, 10).json()["preview"]
    path, body, confirmed = _confirm(app, client, headers, plan, first)
    assert confirmed.status_code == 201
    assert confirmed.json()["receipt"]["status"] == "applied"
    assert _preview(app, client, headers, plan, 11).status_code == 201

    clock.now += 61
    recovered = _preview(app, client, headers, plan, 12)
    assert recovered.status_code == 201
    replay = client.post(path, headers=headers, json=body)
    assert replay.status_code == 201
    assert replay.json() == confirmed.json()


def test_terminal_receipt_is_pruned_only_after_the_replay_window(
    server, monkeypatch
):
    app, client, settings, clock = server
    headers = auth(ready(server))
    monkeypatch.setattr(room_service, "MAX_PREVIEWS", 1)
    monkeypatch.setattr(room_service, "RECEIPT_REPLAY_RETENTION_SECONDS", 2)
    plan = _publish(app, client, headers, clock).json()["plan"]
    app.state.core.room_comfort.worker = _applied_worker(clock)
    first = _preview(app, client, headers, plan, 13).json()["preview"]
    old_path, old_body, confirmed = _confirm(
        app, client, headers, plan, first
    )
    assert confirmed.status_code == 201
    assert _preview(app, client, headers, plan, 14).status_code == 429

    clock.now += 61
    replacement = _preview(app, client, headers, plan, 15)
    assert replacement.status_code == 201
    with sqlite3.connect(settings.database_file) as connection:
        assert connection.execute(
            "SELECT id FROM room_comfort_previews"
        ).fetchall() == [(replacement.json()["preview"]["previewId"],)]
    calls = []
    with TestClient(create_app(settings)) as restarted:
        restarted.app.state.core.room_comfort.worker = lambda command: calls.append(
            command.commandId
        )
        assert restarted.post(
            old_path, headers=headers, json=old_body
        ).status_code == 404
    assert calls == []


def test_unconfirmed_preview_is_protected_through_exact_expiry_boundary(
    server, monkeypatch
):
    app, client, _settings, clock = server
    headers = auth(ready(server))
    monkeypatch.setattr(room_service, "MAX_PREVIEWS", 1)
    plan = _publish(app, client, headers, clock).json()["plan"]
    first = _preview(app, client, headers, plan, 16).json()["preview"]
    clock.now = first["expiresAtMs"] / 1000
    assert _preview(app, client, headers, plan, 17).status_code == 429
    clock.now += 0.001
    assert _preview(app, client, headers, plan, 18).status_code == 201


def test_terminal_receipt_is_protected_through_exact_replay_cutoff(
    server, monkeypatch
):
    app, client, _settings, clock = server
    headers = auth(ready(server))
    monkeypatch.setattr(room_service, "MAX_PREVIEWS", 1)
    monkeypatch.setattr(room_service, "RECEIPT_REPLAY_RETENTION_SECONDS", 31)
    plan = _publish(app, client, headers, clock).json()["plan"]
    app.state.core.room_comfort.worker = _applied_worker(clock)
    first = _preview(app, client, headers, plan, 19).json()["preview"]
    confirmed = _confirm(app, client, headers, plan, first)[2].json()["receipt"]
    clock.now = confirmed["completedAtMs"] / 1000 + 31
    assert _preview(app, client, headers, plan, 20).status_code == 429
    clock.now += 0.001
    assert _preview(app, client, headers, plan, 21).status_code == 201


def test_unknown_and_dispatching_effects_keep_preview_and_plan_parents(
    server, monkeypatch
):
    app, client, settings, clock = server
    headers = auth(ready(server))
    monkeypatch.setattr(room_service, "MAX_PLANS", 4)
    first_plan = _publish(app, client, headers, clock).json()["plan"]
    unknown_preview = _preview(app, client, headers, first_plan, 20).json()[
        "preview"
    ]
    _, _, unknown = _confirm(
        app, client, headers, first_plan, unknown_preview
    )
    assert unknown.json()["receipt"]["status"] == "unknown"

    second_plan = _publish(app, client, headers, clock).json()["plan"]
    dispatching_preview = _preview(
        app, client, headers, second_plan, 21
    ).json()["preview"]
    service = app.state.core.room_comfort
    original = service._complete_dispatch
    service.worker = _applied_worker(clock)
    service._complete_dispatch = lambda *_args: (_ for _ in ()).throw(
        RuntimeError("synthetic crash after provider I/O")
    )
    try:
        assert _confirm(
            app, client, headers, second_plan, dispatching_preview
        )[2].status_code == 503
    finally:
        service._complete_dispatch = original

    _publish(app, client, headers, clock)
    _publish(app, client, headers, clock)
    recovered = _publish(app, client, headers, clock)
    assert recovered.status_code == 200
    with sqlite3.connect(settings.database_file) as connection:
        connection.row_factory = sqlite3.Row
        plan_ids = {
            row["id"]
            for row in connection.execute("SELECT id FROM room_comfort_plans")
        }
        preview_ids = {
            row["id"]
            for row in connection.execute("SELECT id FROM room_comfort_previews")
        }
        dispatch_states = {
            row["state"]
            for row in connection.execute(
                "SELECT state FROM room_comfort_dispatches"
            )
        }
    assert {first_plan["planId"], second_plan["planId"]} <= plan_ids
    assert {unknown_preview["previewId"], dispatching_preview["previewId"]} <= (
        preview_ids
    )
    assert "dispatching" in dispatch_states
    with TestClient(create_app(settings)) as restarted:
        assert restarted.get(
            _root(restarted.app) + "/plan", headers=headers
        ).status_code == 200


def test_all_indispensable_plan_parents_fail_closed_at_capacity(server, monkeypatch):
    app, client, _settings, clock = server
    headers = auth(ready(server))
    monkeypatch.setattr(room_service, "MAX_PLANS", 3)

    for request_number in range(30, 33):
        plan = _publish(app, client, headers, clock).json()["plan"]
        assert _preview(
            app, client, headers, plan, request_number
        ).status_code == 201

    assert _publish(app, client, headers, clock).status_code == 429


def test_retention_validates_hmac_before_pruning_tampered_history(server, monkeypatch):
    app, client, settings, clock = server
    headers = auth(ready(server))
    monkeypatch.setattr(room_service, "MAX_PLANS", 2)
    first = _publish(app, client, headers, clock).json()["plan"]
    assert _publish(app, client, headers, clock).status_code == 200
    with sqlite3.connect(settings.database_file) as connection:
        connection.execute(
            "UPDATE room_comfort_plans SET plan_json='{}' WHERE id=?",
            (first["planId"],),
        )

    response = _publish(app, client, headers, clock)
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "server_unavailable"


@pytest.mark.parametrize("table,column", [
    ("room_comfort_previews", "token_hash"),
    ("room_comfort_dispatches", "result_json"),
])
def test_retention_rejects_tampered_child_envelopes_without_deleting_rows(
    server, monkeypatch, table, column
):
    app, client, settings, clock = server
    headers = auth(ready(server))
    plan = _publish(app, client, headers, clock).json()["plan"]
    first = _preview(app, client, headers, plan, 40).json()["preview"]
    if table == "room_comfort_dispatches":
        assert _confirm(app, client, headers, plan, first)[2].status_code == 201
        monkeypatch.setattr(room_service, "MAX_DISPATCHES", 1)
        second = _preview(app, client, headers, plan, 41).json()["preview"]
    else:
        monkeypatch.setattr(room_service, "MAX_PREVIEWS", 1)
        second = None
    with sqlite3.connect(settings.database_file) as connection:
        before = {
            name: connection.execute(f"SELECT COUNT(*) FROM {name}").fetchone()[0]
            for name in (
                "room_comfort_plans",
                "room_comfort_previews",
                "room_comfort_dispatches",
            )
        }
        key_column = "id" if table == "room_comfort_previews" else "preview_id"
        connection.execute(
            f"UPDATE {table} SET {column}='tampered' WHERE {key_column}=?",
            (first["previewId"],),
        )

    response = (
        _confirm(app, client, headers, plan, second)[2]
        if second is not None
        else _preview(app, client, headers, plan, 42)
    )
    assert response.status_code == 503
    with sqlite3.connect(settings.database_file) as connection:
        after = {
            name: connection.execute(f"SELECT COUNT(*) FROM {name}").fetchone()[0]
            for name in before
        }
    assert after == before


def test_capacity_failure_rolls_back_eligible_retention_deletes(server, monkeypatch):
    app, client, settings, clock = server
    headers = auth(ready(server))
    monkeypatch.setattr(room_service, "MAX_PLANS", 3)
    first = _publish(app, client, headers, clock).json()["plan"]
    second = _publish(app, client, headers, clock).json()["plan"]
    assert _preview(app, client, headers, second, 50).status_code == 201
    third = _publish(app, client, headers, clock).json()["plan"]
    assert _preview(app, client, headers, third, 51).status_code == 201

    with pytest.raises(ApiError, match="comfort_limit_reached"):
        with app.state.core.db.transaction() as connection:
            app.state.core.room_comfort._ensure_capacity(
                connection, clock.now, plans=2
            )
    with sqlite3.connect(settings.database_file) as connection:
        assert {
            row[0]
            for row in connection.execute("SELECT id FROM room_comfort_plans")
        } == {first["planId"], second["planId"], third["planId"]}


def test_current_pointer_rollback_and_equal_time_conflict_fail_closed(
    server, monkeypatch
):
    app, client, settings, clock = server
    headers = auth(ready(server))
    monkeypatch.setattr(room_service, "MAX_PLANS", 2)
    first_body = _publish_body(app, int(clock.now * 1000))
    first = client.put(
        _root(app) + "/plan", headers=headers, json=first_body
    ).json()["plan"]
    exact = client.put(
        _root(app) + "/plan", headers=headers, json=first_body
    )
    assert exact.status_code == 200
    different = _publish_body(app, int(clock.now * 1000))
    different["climate"][0]["temperature"]["value"] -= 1_000
    assert client.put(
        _root(app) + "/plan", headers=headers, json=different
    ).status_code == 409
    clock.now += 1
    second = _publish(app, client, headers, clock).json()["plan"]
    with sqlite3.connect(settings.database_file) as connection:
        connection.execute(
            "UPDATE room_comfort_state SET plan_id=? WHERE singleton=1",
            (first["planId"],),
        )
        before = connection.execute(
            "SELECT COUNT(*) FROM room_comfort_plans"
        ).fetchone()[0]
    response = _publish(app, client, headers, clock)
    assert response.status_code == 503
    with sqlite3.connect(settings.database_file) as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM room_comfort_plans"
        ).fetchone()[0] == before
        assert second["planId"] in {
            row[0]
            for row in connection.execute("SELECT id FROM room_comfort_plans")
        }


def test_ambiguous_current_pointer_fails_startup(server):
    app, _client, settings, clock = server
    headers = auth(ready(server))
    plan = _publish(app, _client, headers, clock).json()["plan"]
    service = app.state.core.room_comfort
    with sqlite3.connect(settings.database_file) as connection:
        connection.row_factory = sqlite3.Row
        row = connection.execute(
            "SELECT * FROM room_comfort_plans WHERE id=?", (plan["planId"],)
        ).fetchone()
        duplicate_id = "d" * 32
        duplicate_plan = room_service.ComfortPlan.model_validate_json(
            row["plan_json"]
        ).model_copy(update={"planId": duplicate_id})
        values = [
            duplicate_id,
            row["policy_json"],
            duplicate_plan.model_dump_json(),
            row["readbacks_json"],
            row["actor_id"],
            row["family_id"],
            row["created_at"],
        ]
        connection.execute(
            "INSERT INTO room_comfort_plans VALUES(?,?,?,?,?,?,?,?)",
            (*values, service._tag("plan", values)),
        )
    with pytest.raises(StartupError, match="invalid_room_comfort_storage"):
        create_app(settings)


@pytest.mark.parametrize("mode", ["null_with_history", "nonnull_without_history"])
def test_current_pointer_presence_must_match_plan_history(server, mode):
    app, client, settings, clock = server
    headers = auth(ready(server))
    _publish(app, client, headers, clock)
    with sqlite3.connect(settings.database_file) as connection:
        if mode == "null_with_history":
            connection.execute(
                "UPDATE room_comfort_state SET plan_id=NULL WHERE singleton=1"
            )
        else:
            connection.execute("PRAGMA foreign_keys=OFF")
            connection.execute(
                "UPDATE room_comfort_state SET plan_id=? WHERE singleton=1",
                ("e" * 32,),
            )
            connection.execute("DELETE FROM room_comfort_plans")
    with pytest.raises(StartupError, match="invalid_room_comfort_storage"):
        create_app(settings)
