"""S09.1 backup cut for current externally visible effects."""

import pytest
from conftest import auth, ready

PASSPHRASE = "Correct horse battery staple 2026"


def _seed_game_command(connection, state, expires_at, *, session_state="open"):
    connection.execute(
        "INSERT INTO game_stream_sessions VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
        (
            "1" * 32,
            "2" * 32,
            "3" * 32,
            "4" * 32,
            1,
            "session-request",
            "5" * 64,
            "{}",
            expires_at,
            session_state,
            1.0,
            "6" * 64,
        ),
    )
    result = {
        "authorized": None,
        "verified": "streaming",
        "unknown": "unknown",
        "rejected": "rejected",
    }[state]
    connection.execute(
        "INSERT INTO game_stream_commands VALUES(?,?,?,?,?,?,?,?,?,?,?)",
        (
            "7" * 32,
            "1" * 32,
            "command-request",
            "8" * 64,
            "stream",
            state,
            result,
            7 if state == "verified" else None,
            1.0,
            None if state == "authorized" else 2.0,
            "9" * 64,
        ),
    )


def _seed_kiosk_command(connection, state, expires_at):
    connection.execute(
        "INSERT INTO kiosk_remote_commands VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
        (
            "a" * 32,
            "b" * 32,
            "c" * 32,
            1,
            "lock",
            expires_at,
            state,
            None if state == "accepted" else "completed",
            "d" * 64,
            1.0,
            None if state == "accepted" else 2.0,
            "e" * 64,
        ),
    )


def _seed_tablet_command(connection, state, expires_at):
    result = {
        "pending": None,
        "delivered": None,
        "completed": "succeeded",
        "expired": "expired",
    }[state]
    connection.execute(
        "INSERT INTO managed_tablet_commands VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (
            1,
            "f" * 32,
            "0" * 32,
            "tablet-request",
            "refreshDashboard",
            "standard",
            1,
            expires_at,
            state,
            result,
            1.0,
            1.5 if state == "delivered" else None,
            None if state in {"pending", "delivered"} else 2.0,
            "1" * 64,
        ),
    )


def _seed(server, effect, state, *, current=True):
    app, _client, _settings, clock = server
    expires_at = clock() + 60 if current else clock() - 1
    with app.state.core.db.connection() as connection:
        connection.execute("PRAGMA foreign_keys=OFF")
        connection.execute("BEGIN IMMEDIATE")
        if effect in {"game", "retired_game"}:
            _seed_game_command(
                connection,
                state,
                expires_at,
                session_state="retired" if effect == "retired_game" else "open",
            )
        elif effect == "kiosk":
            _seed_kiosk_command(connection, state, expires_at)
        else:
            _seed_tablet_command(connection, state, expires_at)
        connection.commit()


@pytest.mark.parametrize(
    ("effect", "state", "blocker"),
    [
        ("game", "authorized", "active_game_stream_command"),
        ("kiosk", "accepted", "active_kiosk_command"),
        ("tablet", "pending", "active_tablet_command"),
        ("tablet", "delivered", "active_tablet_command"),
    ],
)
def test_plan_and_export_block_each_current_unfinished_effect(
    server, effect, state, blocker
):
    _seed(server, effect, state)
    pair = ready(server)

    plan = server[1].get("/api/v1/admin/backups/plan", headers=auth(pair))
    exported = server[1].post(
        "/api/v1/admin/backups/export",
        headers=auth(pair),
        json={"passphrase": PASSPHRASE},
    )

    assert plan.status_code == 200
    assert plan.json() == {
        "status": "blocked",
        "blockers": [blocker],
        "manifest": None,
    }
    assert exported.status_code == 409
    assert exported.json()["error"]["code"] == "backup_blocked"


@pytest.mark.parametrize(
    ("effect", "state"),
    [
        ("game", "authorized"),
        ("kiosk", "accepted"),
        ("tablet", "pending"),
        ("tablet", "delivered"),
    ],
)
def test_expired_effects_do_not_leave_backup_permanently_blocked(
    server, effect, state
):
    _seed(server, effect, state, current=False)
    pair = ready(server)

    response = server[1].get(
        "/api/v1/admin/backups/plan",
        headers=auth(pair),
    )

    assert response.status_code == 200
    assert response.json()["status"] == "ready"
    assert response.json()["blockers"] == []


@pytest.mark.parametrize(
    ("effect", "state"),
    [
        ("game", "verified"),
        ("game", "unknown"),
        ("game", "rejected"),
        ("retired_game", "authorized"),
        ("kiosk", "completed"),
        ("tablet", "completed"),
        ("tablet", "expired"),
    ],
)
def test_terminal_external_effect_history_remains_backup_ready(
    server, effect, state
):
    _seed(server, effect, state)
    pair = ready(server)

    response = server[1].get(
        "/api/v1/admin/backups/plan",
        headers=auth(pair),
    )

    assert response.status_code == 200
    assert response.json()["status"] == "ready"
    assert response.json()["blockers"] == []


def test_current_effect_blockers_have_one_stable_public_order(server):
    _seed(server, "tablet", "pending")
    _seed(server, "kiosk", "accepted")
    _seed(server, "game", "authorized")
    pair = ready(server)

    response = server[1].get(
        "/api/v1/admin/backups/plan",
        headers=auth(pair),
    )

    assert response.status_code == 200
    assert response.json() == {
        "status": "blocked",
        "blockers": [
            "active_tablet_command",
            "active_kiosk_command",
            "active_game_stream_command",
        ],
        "manifest": None,
    }
