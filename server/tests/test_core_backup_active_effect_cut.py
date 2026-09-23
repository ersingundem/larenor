"""S09.1 backup cut for externally visible in-flight effects."""

import pytest
from conftest import auth, ready


def _seed_proxmox(connection, states):
    for sequence, result_code in enumerate(states, 1):
        connection.execute(
            "INSERT INTO proxmox_power_journal VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                sequence,
                "1" * 32,
                "2" * 32,
                "3" * 32,
                "command_status",
                "start",
                result_code if result_code in {"accepted", "executing"} else "succeeded",
                result_code,
                1,
                1,
                1,
                1,
                1,
                sequence,
                None,
                float(sequence),
                "0" * 64,
                "4" * 64,
            ),
        )


def _seed_kiosk(connection, state):
    connection.execute(
        "INSERT INTO kiosk_remote_commands VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
        (
            "5" * 32,
            "6" * 32,
            "7" * 32,
            1,
            "lock",
            9999999999.0,
            state,
            None if state == "accepted" else "completed",
            "8" * 64,
            1.0,
            None if state == "accepted" else 2.0,
            "9" * 64,
        ),
    )


def _seed_music_rotation(connection, state):
    connection.execute(
        "INSERT INTO music_assistant_key_rotations VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (
            "a" * 32,
            1,
            state,
            "b" * 32,
            1,
            "c" * 32,
            "d" * 32,
            "e" * 32,
            "f" * 32,
            1,
            1,
            "1" * 32,
            1,
            1,
            1,
            b"0" * 12,
            b"ciphertext",
        ),
    )


def _seed(server, effect, state):
    app = server[0]
    with app.state.core.db.connection() as connection:
        connection.execute("PRAGMA foreign_keys=OFF")
        connection.execute("BEGIN IMMEDIATE")
        if effect == "proxmox":
            _seed_proxmox(connection, state)
        elif effect == "kiosk":
            _seed_kiosk(connection, state)
        else:
            _seed_music_rotation(connection, state)
        connection.commit()


@pytest.mark.parametrize(
    ("effect", "state", "blocker"),
    [
        ("proxmox", ("accepted",), "active_proxmox_command"),
        ("proxmox", ("executing",), "active_proxmox_command"),
        ("kiosk", "accepted", "active_kiosk_command"),
        ("rotation", "preparing", "active_music_key_rotation"),
        ("rotation", "activated", "active_music_key_rotation"),
    ],
)
def test_backup_plan_blocks_each_unfinished_external_effect(
    server, effect, state, blocker
):
    _seed(server, effect, state)
    pair = ready(server)

    response = server[1].get(
        "/api/v1/admin/backups/plan",
        headers=auth(pair),
    )

    assert response.status_code == 200
    assert response.json() == {
        "status": "blocked",
        "blockers": [blocker],
        "manifest": None,
    }


@pytest.mark.parametrize(
    ("effect", "state"),
    [
        ("proxmox", ("accepted", "completed")),
        ("kiosk", "completed"),
        ("rotation", "retired"),
    ],
)
def test_backup_plan_ignores_terminal_external_effect_history(server, effect, state):
    _seed(server, effect, state)
    pair = ready(server)

    response = server[1].get(
        "/api/v1/admin/backups/plan",
        headers=auth(pair),
    )

    assert response.status_code == 200
    assert response.json()["status"] == "ready"
    assert response.json()["blockers"] == []


def test_new_effect_blockers_have_one_stable_public_order(server):
    _seed(server, "rotation", "preparing")
    _seed(server, "proxmox", ("executing",))
    _seed(server, "kiosk", "accepted")
    pair = ready(server)

    response = server[1].get(
        "/api/v1/admin/backups/plan",
        headers=auth(pair),
    )

    assert response.status_code == 200
    assert response.json() == {
        "status": "blocked",
        "blockers": [
            "active_music_key_rotation",
            "active_proxmox_command",
            "active_kiosk_command",
        ],
        "manifest": None,
    }
