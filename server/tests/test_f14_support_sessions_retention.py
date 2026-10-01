import uuid

from fastapi.testclient import TestClient

from larenor_server.app import create_app
from larenor_server.config import Settings

from conftest import Clock, auth, login, ready


def _settings(tmp_path, clock):
    root = tmp_path.resolve()
    return Settings(
        root / "data",
        root / "secrets/vault.key",
        clock=clock,
        login_ip_limit=100,
        login_account_limit=100,
        login_global_limit=100,
    )


def _root(app):
    context = app.state.core.context
    return f"/api/v1/support-sessions/{context.coreId}/{context.homeId}"


def _create(client, root, actor, clock, index):
    return client.post(
        root,
        headers=auth(actor),
        json={
            "schemaVersion": 1,
            "requestKey": f"retention-request-{index:04d}",
            "supporterId": "retention.supporter",
            "supporterName": "Retention fixture",
            "permissions": ["core:health.read"],
            "expiresAt": clock.now + 60,
        },
    )


def _revoke(client, root, actor, session):
    return client.post(
        f"{root}/{session['id']}/revoke",
        headers=auth(actor),
        json={"schemaVersion": 1, "expectedRevision": session["revision"]},
    )


def _external(token):
    return {
        "Authorization": "Bearer " + token,
        "X-Larenor-Supporter": "retention.supporter",
    }


def _access(client, root, token):
    return client.post(
        root + "/access",
        headers=_external(token),
        json={"schemaVersion": 1, "permission": "core:health.read"},
    )


def test_normal_core_restart_releases_expired_session_capacity(tmp_path):
    clock = Clock()
    settings = _settings(tmp_path, clock)
    app = create_app(settings)
    with TestClient(app) as client:
        actor = ready((app, client, settings, clock))
        root = _root(app)
        for index in range(64):
            created = _create(client, root, actor, clock, index)
            assert created.status_code == 201, created.text

    clock.now += 60 + 24 * 60 * 60 + 1
    with TestClient(create_app(settings)) as restarted:
        actor = login(
            restarted,
            "admin",
            "Synthetic new password 2026",
            "Retention restart",
        ).json()
        created = _create(restarted, root, actor, clock, 64)
        assert created.status_code == 201, created.text


def test_live_and_recent_terminal_sessions_are_not_evicted_for_capacity(tmp_path):
    clock = Clock()
    settings = _settings(tmp_path, clock)
    app = create_app(settings)
    with TestClient(app) as client:
        actor = ready((app, client, settings, clock))
        root = _root(app)
        first = _create(client, root, actor, clock, 0).json()
        assert _revoke(client, root, actor, first["session"]).status_code == 200
        assert _access(client, root, first["accessToken"]).status_code == 401
        for index in range(1, 64):
            assert _create(client, root, actor, clock, index).status_code == 201

        duplicate = _create(client, root, actor, clock, 0)
        assert duplicate.status_code == 409
        assert duplicate.json()["error"]["code"] == "support_session_token_already_issued"
        full = _create(client, root, actor, clock, 64)
        assert full.status_code == 429
        assert full.json()["error"]["code"] == "support_session_limit_reached"
        with app.state.core.db.connection() as connection:
            assert connection.execute("SELECT COUNT(*) FROM support_sessions").fetchone()[0] == 64


def test_terminal_replay_window_is_inclusive_at_exact_cutoff(tmp_path):
    clock = Clock()
    settings = _settings(tmp_path, clock)
    app = create_app(settings)
    with TestClient(app) as client:
        actor = ready((app, client, settings, clock))
        root = _root(app)
        session = _create(client, root, actor, clock, 0).json()["session"]
        assert _revoke(client, root, actor, session).status_code == 200
        service = app.state.core.support_sessions

        clock.now += 24 * 60 * 60
        with app.state.core.db.transaction() as connection:
            assert service._compact_terminal_history(connection, clock.now)[0] == 1
        clock.now += 0.001
        with app.state.core.db.transaction() as connection:
            assert service._compact_terminal_history(connection, clock.now)[0] == 0


def test_expired_session_event_history_releases_capacity_without_old_token_reuse(tmp_path):
    clock = Clock()
    settings = _settings(tmp_path, clock)
    app = create_app(settings)
    with TestClient(app) as client:
        actor = ready((app, client, settings, clock))
        root = _root(app)
        old = _create(client, root, actor, clock, 0).json()
        service = app.state.core.support_sessions
        with app.state.core.db.transaction() as connection:
            for index in range(1024):
                row = {
                    "id": uuid.uuid4().hex,
                    "session_id": old["session"]["id"],
                    "permission": "core:health.read",
                    "outcome": "allowed",
                    "created_at": clock.now + index / 10_000,
                }
                row["record_tag"] = service._event_tag(row)
                connection.execute(
                    "INSERT INTO support_session_events VALUES(?,?,?,?,?,?)",
                    tuple(row.values()),
                )

        clock.now += 60 + 24 * 60 * 60 + 1
        actor = login(
            client,
            "admin",
            "Synthetic new password 2026",
            "Retention event recovery",
        ).json()
        fresh = _create(client, root, actor, clock, 1)
        assert fresh.status_code == 201, fresh.text
        assert _access(client, root, fresh.json()["accessToken"]).status_code == 200
        assert _access(client, root, old["accessToken"]).status_code == 401
        with app.state.core.db.connection() as connection:
            assert connection.execute("SELECT COUNT(*) FROM support_session_events").fetchone()[0] == 1
            assert connection.execute(
                "SELECT COUNT(*) FROM support_sessions WHERE id=?",
                (old["session"]["id"],),
            ).fetchone()[0] == 0


def test_retention_validates_session_rows_and_rolls_back_on_tamper(tmp_path):
    clock = Clock()
    settings = _settings(tmp_path, clock)
    app = create_app(settings)
    with TestClient(app) as client:
        actor = ready((app, client, settings, clock))
        root = _root(app)
        first = _create(client, root, actor, clock, 0).json()["session"]
        second = _create(client, root, actor, clock, 1).json()["session"]
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE support_sessions SET supporter_name='tampered' WHERE id=?",
                (second["id"],),
            )
        clock.now += 60 + 24 * 60 * 60 + 1
        actor = login(
            client,
            "admin",
            "Synthetic new password 2026",
            "Retention tamper",
        ).json()

        response = _create(client, root, actor, clock, 2)
        assert response.status_code == 503, response.text
        with app.state.core.db.connection() as connection:
            ids = {
                row["id"]
                for row in connection.execute("SELECT id FROM support_sessions")
            }
        assert ids == {first["id"], second["id"]}


def test_retention_validates_event_rows_and_rolls_back_on_tamper(tmp_path):
    clock = Clock()
    settings = _settings(tmp_path, clock)
    app = create_app(settings)
    with TestClient(app) as client:
        actor = ready((app, client, settings, clock))
        root = _root(app)
        created = _create(client, root, actor, clock, 0).json()
        assert _access(client, root, created["accessToken"]).status_code == 200
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE support_session_events SET permission='session:activity.read'"
            )
        clock.now += 60 + 24 * 60 * 60 + 1
        actor = login(
            client,
            "admin",
            "Synthetic new password 2026",
            "Retention event tamper",
        ).json()

        response = _create(client, root, actor, clock, 1)
        assert response.status_code == 503, response.text
        with app.state.core.db.connection() as connection:
            assert connection.execute("SELECT COUNT(*) FROM support_sessions").fetchone()[0] == 1
            assert connection.execute("SELECT COUNT(*) FROM support_session_events").fetchone()[0] == 1
