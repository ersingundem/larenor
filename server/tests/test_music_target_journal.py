"""Durable and tamper-evident Music Assistant target command journal."""

import re

from fastapi.testclient import TestClient

from conftest import auth
from larenor_server.app import create_app
from test_admin import activate, create
from test_music_playback import discovered
from test_music_target_authority import (
    BASE, inventory_request, preview_request,
)


def confirmed(server, seed="c"):
    pair, setup, readiness, worker, playback = discovered(server)
    intent = preview_request(
        server, pair, setup, readiness, playback,
        requestId=seed * 32, operation="pause", volumeLevel=None,
    )
    preview = server[1].post(
        BASE + "/previews", headers=auth(pair), json=intent
    ).json()["preview"]
    confirmation = {
        "requestId": chr(ord(seed) + 1) * 32,
        "previewId": preview["id"],
        "expectedPreviewRevision": 1,
        "planHash": preview["planHash"],
    }
    command = server[1].post(
        BASE + "/commands", headers=auth(pair), json=confirmation
    ).json()["command"]
    return pair, setup, readiness, worker, playback, confirmation, command


def inventory_body(server, pair, setup, readiness, playback):
    return inventory_request(server, pair, setup, readiness, playback)


def test_status_cancel_history_and_integrity_are_idempotent_and_bounded(server):
    pair, setup, readiness, worker, playback, _confirmation, command = confirmed(
        server)
    status = server[1].get(
        BASE + "/commands/" + command["id"], headers=auth(pair))
    assert status.status_code == 200
    assert status.json()["command"] == command

    cancel = {"requestId": "e" * 32, "expectedRevision": 1}
    first = server[1].post(
        BASE + "/commands/" + command["id"] + "/cancel",
        headers=auth(pair), json=cancel)
    second = server[1].post(
        BASE + "/commands/" + command["id"] + "/cancel",
        headers=auth(pair), json=cancel)
    conflict = server[1].post(
        BASE + "/commands/" + command["id"] + "/cancel",
        headers=auth(pair),
        json={"requestId": "f" * 32, "expectedRevision": 1})
    assert first.status_code == 200 and first.json() == second.json()
    assert first.json()["command"]["state"] == "cancelled"
    assert first.json()["command"]["revision"] == 2
    assert conflict.status_code == 409

    request = inventory_body(server, pair, setup, readiness, playback)
    history = server[1].post(
        BASE + "/history", headers=auth(pair), json=request | {"limit": 1})
    assert history.status_code == 200
    assert history.json() == {
        "commands": [first.json()["command"]], "nextBefore": None}
    integrity = server[1].post(
        BASE + "/integrity", headers=auth(pair), json=request)
    assert integrity.status_code == 200
    assert integrity.json()["integrity"]["verified"] is True
    assert integrity.json()["integrity"]["commandCount"] == 1
    assert re.fullmatch(
        r"[0-9a-f]{64}", integrity.json()["integrity"]["headHash"])
    assert integrity.json()["integrity"]["installAvailable"] is False
    assert worker.calls == []


def test_journal_tampering_and_admin_pin_substitution_fail_closed(server):
    app, client, _, _ = server
    pair, setup, readiness, worker, playback, _confirmation, command = confirmed(
        server, "a")
    create(client, pair, "target-journal-member")
    member = activate(client, "target-journal-member")
    for headers, expected in (
        ({"X-Larenor-Settings-PIN": "1234"}, 401),
        (auth(member) | {"X-Larenor-Settings-PIN": "1234"}, 403),
    ):
        response = client.get(BASE + "/commands/" + command["id"],
                              headers=headers)
        assert response.status_code == expected

    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE music_target_commands SET operation=? WHERE id=?",
            ("play", command["id"]))
    request = inventory_body(server, pair, setup, readiness, playback)
    for method, path, body in (
        ("get", BASE + "/commands/" + command["id"], None),
        ("post", BASE + "/history", request | {"limit": 10}),
        ("post", BASE + "/integrity", request),
    ):
        response = getattr(client, method)(
            path, headers=auth(pair), **({} if body is None else {"json": body}))
        assert response.status_code == 503
    assert worker.calls == []


def test_expired_preview_and_secret_extras_never_create_journal_rows(server):
    app, client, _, clock = server
    pair, setup, readiness, worker, playback = discovered(server)
    intent = preview_request(
        server, pair, setup, readiness, playback,
        requestId="1" * 32, operation="pause", volumeLevel=None,
    )
    preview = client.post(
        BASE + "/previews", headers=auth(pair), json=intent).json()["preview"]
    clock.now += 601
    expired = client.post(BASE + "/commands", headers=auth(pair), json={
        "requestId": "2" * 32, "previewId": preview["id"],
        "expectedPreviewRevision": 1, "planHash": preview["planHash"],
    })
    secret = client.post(
        BASE + "/history", headers=auth(pair),
        json=inventory_body(server, pair, setup, readiness, playback)
        | {"limit": 10, "cookie": "private-cookie"})
    assert expired.status_code == 409
    assert secret.status_code == 400
    assert "private-cookie" not in secret.text
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM music_target_commands").fetchone()[0] == 0
    assert worker.calls == []


def test_restart_retires_unfinished_effect_to_unknown_without_retry(server):
    app, _client, settings, clock = server
    pair, _setup, _readiness, worker, _playback, confirmation, command = confirmed(
        server, "6")
    manager = app.state.core.music_target_authority
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    with app.state.core.db.transaction() as connection:
        preview = connection.execute(
            "SELECT * FROM music_target_command_previews WHERE id=?",
            (command["previewId"],)).fetchone()
        row = {
            "command_id": command["id"], "execution_id": "8" * 32,
            "dispatch_request_id": "9" * 32, "actor_id": actor.id,
            "actor_revision": preview["actor_revision"],
            "family_id": actor.family_id,
            "installation_id": preview["installation_id"],
            "installation_revision": preview["installation_revision"],
            "core_revision": preview["core_revision"],
            "player_revision": preview["player_revision"],
            "provider_digest": preview["provider_digest"], "state": "pending",
            "created_at": int(clock.now), "updated_at": int(clock.now),
            "result_hash": "0" * 64,
        }
        row["event_hash"] = manager._effect_hash(row)
        connection.execute('''INSERT INTO music_target_effect_attempts(
            command_id,execution_id,dispatch_request_id,actor_id,actor_revision,
            family_id,installation_id,installation_revision,core_revision,
            player_revision,provider_digest,state,created_at,updated_at,
            result_hash,event_hash) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
            tuple(row.values()))

    with TestClient(create_app(settings)) as restarted:
        status = restarted.get(
            BASE + "/commands/" + command["id"], headers=auth(pair))
        repeated = restarted.post(
            BASE + "/commands", headers=auth(pair), json=confirmation)
        assert status.status_code == 200 and repeated.status_code == 201
        assert status.json() == repeated.json()
        assert status.json()["command"]["state"] == "unknown"
        assert status.json()["command"]["errorCode"] == "effect_unknown"
        assert status.json()["command"]["result"] == {
            "state": "unknown", "code": "effect_unknown"}
        with restarted.app.state.core.db.connection() as connection:
            saved = connection.execute(
                "SELECT state FROM music_target_effect_attempts WHERE command_id=?",
                (command["id"],)).fetchone()
            assert saved["state"] == "unknown"
            assert connection.execute(
                "SELECT COUNT(*) FROM music_target_effect_attempts WHERE command_id=?",
                (command["id"],)).fetchone()[0] == 1
    assert worker.calls == []
