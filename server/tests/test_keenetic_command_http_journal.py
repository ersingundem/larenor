import json

import pytest
from fastapi.testclient import TestClient

from larenor_server.app import create_app
from larenor_server.errors import ApiError, StartupError
from larenor_server.keenetic_commands.journal import KeeneticCommandJournal
from larenor_server.keenetic_commands.service import KeeneticCommandAuthority

from conftest import auth, ready
from test_admin import activate, create
from test_keenetic_command_authority import Actor, Harness, request, state


def install_fixture_authority(app, harness):
    def revision(actor):
        with app.state.core.db.connection() as connection:
            app.state.core.auth.assert_current(connection, actor)
            return connection.execute(
                "SELECT revision FROM users WHERE id=?", (actor.id,)
            ).fetchone()["revision"]

    app.state.core.keenetic_commands = KeeneticCommandAuthority(
        authorize=harness.authorize,
        observe=harness.observe,
        effect=harness.effect,
        journal=app.state.core.keenetic_command_journal,
        wall_clock=app.state.core.settings.clock,
        actor_revision=revision,
    )


def scoped_request(app, action="guest_wifi_enable"):
    context = app.state.core.context
    target = state().model_copy(update={"coreId": context.coreId, "homeId": context.homeId})
    body = request(action, current=target).model_dump()
    with app.state.core.db.connection() as connection:
        body["expectedUserRevision"] = connection.execute(
            "SELECT revision FROM users WHERE username='admin'"
        ).fetchone()["revision"]
    return body


def test_http_preview_confirm_status_history_and_integrity_are_admin_only(server):
    app, client, _, _ = server
    pair = ready(server)
    harness = Harness(state().model_copy(update={
        "coreId": app.state.core.context.coreId,
        "homeId": app.state.core.context.homeId,
    }))
    install_fixture_authority(app, harness)
    body = scoped_request(app)
    resource = body["target"]["resourceId"]
    root = f"/api/v1/admin/homes/{body['target']['coreId']}/{body['target']['homeId']}/resources/{resource}/keenetic/commands"

    preview_response = client.post(root + "/preview", headers=auth(pair), json=body)
    assert preview_response.status_code == 200
    preview = preview_response.json()["preview"]
    assert "confirmToken" in preview

    confirmed = client.post(
        root + f"/{preview['id']}/confirm",
        headers=auth(pair),
        json={"token": preview["confirmToken"]},
    )
    assert confirmed.status_code == 200
    assert confirmed.json()["receipt"]["status"] == "succeeded"
    assert "confirmToken" not in confirmed.text

    status = client.get(root + f"/status/{body['requestId']}", headers=auth(pair))
    assert status.status_code == 200
    assert status.json()["command"]["status"] == "succeeded"
    assert body["idempotencyKey"] not in status.text

    history = client.get(root + "/history", headers=auth(pair))
    assert history.status_code == 200
    assert [event["status"] for event in history.json()["events"]] == [
        "accepted", "executing", "succeeded"
    ]
    integrity = client.get(root + "/integrity", headers=auth(pair))
    assert integrity.status_code == 200
    assert integrity.json()["integrity"]["verified"] is True
    assert integrity.json()["integrity"]["sequence"] == 3

    with app.state.core.db.connection() as connection:
        raw = " ".join(
            str(value)
            for table in ("keenetic_command_records", "keenetic_command_events")
            for row in connection.execute(f"SELECT * FROM {table}")
            for value in row
        )
    assert preview["confirmToken"] not in raw
    assert body["idempotencyKey"] not in raw

    create(client, pair, "keenetic-member")
    member = activate(client, "keenetic-member")

    for method, path, payload in [
        ("post", root + "/preview", body),
        ("get", root + f"/status/{body['requestId']}", None),
        ("get", root + "/history", None),
        ("get", root + "/integrity", None),
    ]:
        response = getattr(client, method)(path, json=payload) if payload else getattr(client, method)(path)
        assert response.status_code == 401
        member_response = (
            getattr(client, method)(path, headers=auth(member), json=payload)
            if payload
            else getattr(client, method)(path, headers=auth(member))
        )
        assert member_response.status_code == 403


def test_cancel_is_persisted_and_confirmation_cannot_replay(server):
    app, client, _, _ = server
    pair = ready(server)
    harness = Harness(state().model_copy(update={
        "coreId": app.state.core.context.coreId,
        "homeId": app.state.core.context.homeId,
    }))
    install_fixture_authority(app, harness)
    body = scoped_request(app)
    resource = body["target"]["resourceId"]
    root = f"/api/v1/admin/homes/{body['target']['coreId']}/{body['target']['homeId']}/resources/{resource}/keenetic/commands"
    preview = client.post(root + "/preview", headers=auth(pair), json=body).json()["preview"]
    assert client.post(root + f"/{preview['id']}/cancel", headers=auth(pair)).json()["receipt"]["status"] == "cancelled"
    result = client.post(root + f"/{preview['id']}/confirm", headers=auth(pair), json={"token": preview["confirmToken"]})
    assert result.json()["receipt"]["status"] == "cancelled"
    assert harness.effects == []


def test_journal_detects_modified_record_or_chain(server):
    app, _, _, _ = server
    pair = ready(server)
    harness = Harness(state().model_copy(update={
        "coreId": app.state.core.context.coreId,
        "homeId": app.state.core.context.homeId,
    }))
    install_fixture_authority(app, harness)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    app.state.core.keenetic_commands.preview(actor, scoped_request(app))
    journal = app.state.core.keenetic_command_journal
    assert journal.integrity(actor)["integrity"]["verified"] is True
    with app.state.core.db.transaction() as connection:
        connection.execute("UPDATE keenetic_command_events SET status='failed' WHERE sequence=1")
    with pytest.raises(ApiError, match="keenetic_command_integrity_failed"):
        journal.history(actor)


def test_restart_turns_unfinished_accepted_command_unknown_without_effect(server):
    app, _, settings, _ = server
    pair = ready(server)
    harness = Harness(state().model_copy(update={
        "coreId": app.state.core.context.coreId,
        "homeId": app.state.core.context.homeId,
    }))
    install_fixture_authority(app, harness)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    app.state.core.keenetic_commands.preview(actor, scoped_request(app))

    reopened_app = create_app(settings)
    with TestClient(reopened_app):
        fresh = reopened_app.state.core.auth.authenticate(pair["accessToken"])
        result = reopened_app.state.core.keenetic_command_journal.status(
            fresh, scoped_request(app)["requestId"]
        )
        assert result["command"]["status"] == "unknown"
        assert harness.effects == []
