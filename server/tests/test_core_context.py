"""Persistent single-home identity through the real startup and HTTP boundary."""

from concurrent.futures import ThreadPoolExecutor
import hashlib
import hmac
import re
import sqlite3
from threading import Barrier

import pytest
from fastapi.testclient import TestClient

from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.database import Database
from larenor_server.errors import StartupError
import larenor_server.core as core_module

from conftest import auth, bootstrap_password, document, login, ready
from test_admin import activate, create


PATH = "/api/v1/context"


def context(client, pair):
    response = client.get(PATH, headers=auth(pair))
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    value = response.json()
    assert set(value) == {"schemaVersion", "coreId", "homeId"}
    assert type(value["schemaVersion"]) is int and value["schemaVersion"] == 1
    assert re.fullmatch(r"[0-9a-f]{32}", value["coreId"])
    assert re.fullmatch(r"[0-9a-f]{32}", value["homeId"])
    return value


def legacy_v2(app):
    with app.state.core.db.transaction() as connection:
        connection.execute("DROP TABLE IF EXISTS core_context")
        connection.execute("UPDATE metadata SET value='2' WHERE key='schema_version'")


def persisted(app):
    with app.state.core.db.connection() as connection:
        return [tuple(row) for row in connection.execute("SELECT * FROM core_context")]


def test_ready_admin_and_member_read_the_same_typed_context_without_secrets(server):
    _app, client, _settings, _clock = server
    admin = ready(server)
    expected = context(client, admin)
    create(client, admin)
    member = activate(client, "member")
    assert context(client, member) == expected
    refreshed = client.post("/api/v1/auth/refresh", json={"refreshToken": member["refreshToken"]})
    assert refreshed.status_code == 200
    assert context(client, refreshed.json()) == expected
    schema = client.get("/api/v1/openapi.json", headers=auth(admin)).json()
    operation = schema["paths"][PATH]["get"]
    assert operation["security"] == [{"DeviceAccessToken": []}]
    reference = operation["responses"]["200"]["content"]["application/json"]["schema"]["$ref"]
    model = schema["components"]["schemas"][reference.rsplit("/", 1)[-1]]
    assert set(model["required"]) == set(expected)
    assert set(model["properties"]) == set(expected)
    assert model["additionalProperties"] is False


def test_anonymous_and_initial_password_sessions_cannot_read_context(server):
    _app, client, settings, _clock = server
    anonymous = client.get(PATH)
    assert anonymous.status_code == 401
    assert anonymous.json()["error"]["code"] == "invalid_session"
    initial = login(client, "admin", bootstrap_password(settings)).json()
    blocked = client.get(PATH, headers=auth(initial))
    assert blocked.status_code == 403
    assert blocked.json()["error"]["code"] == "password_change_required"
    assert "coreId" not in blocked.text and "homeId" not in blocked.text


@pytest.mark.parametrize("state", ["expired", "revoked", "disabled"])
def test_invalidated_sessions_cannot_read_context(server, state):
    _app, client, settings, clock = server
    admin = ready(server)
    create(client, admin)
    member = activate(client, "member")
    context(client, member)
    if state == "expired":
        clock.now += settings.access_ttl_seconds + 1
    elif state == "revoked":
        assert client.post("/api/v1/auth/logout", headers=auth(member)).status_code == 204
    else:
        response = client.patch(f'/api/v1/admin/users/{member["user"]["id"]}', headers=auth(admin),
                                json={"expectedRevision": 2, "disabled": True})
        assert response.status_code == 200
    response = client.get(PATH, headers=auth(member))
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_session"


def test_context_is_read_only_and_has_no_arbitrary_home_lookup(server):
    _app, client, _settings, _clock = server
    pair = ready(server)
    before = context(client, pair)
    for method in ("POST", "PUT", "PATCH", "DELETE"):
        assert client.request(method, PATH, headers=auth(pair)).status_code == 405
    assert client.get(PATH + "/" + "a" * 32, headers=auth(pair)).status_code == 404
    assert context(client, pair) == before


def test_restart_keeps_identity_credentials_vault_key_and_existing_session(server):
    app, client, settings, _clock = server
    pair = ready(server)
    expected = context(client, pair)
    assert client.put("/api/v1/vault", headers=auth(pair),
                      json={"expectedRevision": 0, "document": document()}).status_code == 200
    key = settings.key_file.read_bytes()
    before = persisted(app)
    for _ in range(2):
        restarted = create_app(settings)
        with TestClient(restarted) as other:
            assert context(other, pair) == expected
            assert other.get("/api/v1/vault", headers=auth(pair)).json()["document"] == document()
        assert persisted(restarted) == before
        assert not restarted.state.core.bootstrap_created
        assert settings.key_file.read_bytes() == key
        assert not settings.effective_bootstrap_file.exists()
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()[0] == "3"
        assert connection.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 1


def test_independent_fresh_databases_get_distinct_identities(server, tmp_path):
    _app, client, _settings, clock = server
    first = context(client, ready(server))
    settings = Settings(tmp_path / "other/data", tmp_path / "other/secrets/key", clock=clock)
    app = create_app(settings)
    with TestClient(app) as other:
        second = context(other, ready((app, other, settings, clock)))
    assert first["coreId"] != second["coreId"]
    assert first["homeId"] != second["homeId"]


def test_v2_upgrade_preserves_auth_and_vault_and_commits_identity_once(server):
    app, client, settings, _clock = server
    pair = ready(server)
    assert client.put("/api/v1/vault", headers=auth(pair),
                      json={"expectedRevision": 0, "document": document()}).status_code == 200
    key = settings.key_file.read_bytes()
    legacy_v2(app)
    with app.state.core.db.connection() as connection:
        user = tuple(connection.execute("SELECT * FROM users").fetchone())
        encrypted = tuple(connection.execute("SELECT * FROM vaults").fetchone())
        key_check = connection.execute("SELECT value FROM metadata WHERE key='key_check'").fetchone()[0]
    upgraded = create_app(settings)
    with TestClient(upgraded) as current:
        expected = context(current, pair)
        assert current.get("/api/v1/vault", headers=auth(pair)).json()["document"] == document()
    with upgraded.state.core.db.connection() as connection:
        assert tuple(connection.execute("SELECT * FROM users").fetchone()) == user
        assert tuple(connection.execute("SELECT * FROM vaults").fetchone()) == encrypted
        assert connection.execute("SELECT value FROM metadata WHERE key='key_check'").fetchone()[0] == key_check
        assert connection.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()[0] == "3"
    assert settings.key_file.read_bytes() == key
    assert not upgraded.state.core.bootstrap_created
    with TestClient(create_app(settings)) as current:
        assert context(current, pair) == expected


@pytest.mark.parametrize("fresh", [True, False])
def test_identity_and_schema_marker_roll_back_with_later_migration_failure(server, tmp_path, monkeypatch, fresh):
    app, _client, settings, _clock = server
    if fresh:
        settings = Settings(tmp_path / "new/data", tmp_path / "new/secrets/key")
    else:
        legacy_v2(app)
    original = core_module.migrate_services

    def interrupted(connection):
        original(connection)
        raise sqlite3.OperationalError("synthetic-only migration failure")

    with monkeypatch.context() as patch:
        patch.setattr(core_module, "migrate_services", interrupted)
        with pytest.raises(StartupError, match="^storage_initialization_failed$"):
            create_app(settings)
    if fresh:
        assert not settings.database_file.exists()
        pending = list(settings.data_dir.glob(".initialize-*.sqlite3"))
        assert len(pending) == 1
        database = Database(pending[0])
    else:
        database = app.state.core.db
    with database.connection() as connection:
        assert connection.execute("SELECT name FROM sqlite_master WHERE name='core_context'").fetchone() is None
        marker = connection.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()
        assert marker is None if fresh else marker[0] == "2"
    restored = create_app(settings)
    assert len(persisted(restored)) == 1


@pytest.mark.parametrize("legacy", [True, False])
def test_concurrent_startups_publish_one_complete_identity(server, tmp_path, legacy):
    app, _client, settings, _clock = server
    if legacy:
        legacy_v2(app)
    else:
        settings = Settings(tmp_path / "concurrent/data", tmp_path / "concurrent/secrets/key")
    barrier = Barrier(4)

    def start(_):
        barrier.wait(timeout=5)
        return create_app(settings)

    with ThreadPoolExecutor(max_workers=4) as pool:
        apps = list(pool.map(start, range(4)))
    rows = [persisted(item) for item in apps]
    assert all(len(value) == 1 and value == rows[0] for value in rows)
    assert sum(item.state.core.bootstrap_created for item in apps) == (0 if legacy else 1)


@pytest.mark.parametrize("mutation", [
    "DROP TABLE core_context",
    "DELETE FROM core_context",
    "UPDATE core_context SET schema_version=2",
    "UPDATE core_context SET core_id='synthetic-private-payload'",
    "UPDATE core_context SET home_id=NULL",
    "UPDATE core_context SET core_id='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'",
    "UPDATE core_context SET home_id='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'",
    "UPDATE core_context SET core_id=home_id,home_id=core_id",
    "UPDATE core_context SET authentication_tag='ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'",
    "UPDATE core_context SET authentication_tag=x'80'",
    "UPDATE core_context SET singleton=2",
    "INSERT INTO core_context SELECT * FROM core_context",
])
def test_schema3_missing_or_corrupt_context_fails_without_silent_regeneration(server, mutation):
    app, _client, settings, _clock = server
    ready(server)
    with app.state.core.db.transaction() as connection:
        # Model corrupt/restored storage without relying on live SQL constraints.
        connection.execute("CREATE TABLE altered_context AS SELECT * FROM core_context")
        connection.execute("DROP TABLE core_context")
        connection.execute("ALTER TABLE altered_context RENAME TO core_context")
        connection.execute(mutation)
        before = list(connection.iterdump())
    with pytest.raises(StartupError, match="^invalid_core_context$"):
        create_app(settings)
    with app.state.core.db.connection() as connection:
        assert list(connection.iterdump()) == before
    assert not settings.effective_bootstrap_file.exists()


def test_v2_with_context_fragments_is_rejected_instead_of_overwritten(server):
    app, _client, settings, _clock = server
    before = persisted(app)
    with app.state.core.db.transaction() as connection:
        connection.execute("UPDATE metadata SET value='2' WHERE key='schema_version'")
    with pytest.raises(StartupError, match="^invalid_core_context$"):
        create_app(settings)
    assert persisted(app) == before


def test_wrong_vault_key_never_creates_legacy_identity(server, monkeypatch):
    app, _client, settings, _clock = server
    legacy_v2(app)
    settings.key_file.write_bytes(b"x" * 32)

    def forbidden(*_):
        pytest.fail("Identity migration ran before key validation")

    monkeypatch.setattr(core_module, "migrate_context", forbidden)
    with pytest.raises(StartupError, match="^existing_database_invalid_or_wrong_key$"):
        create_app(settings)
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT name FROM sqlite_master WHERE name='core_context'").fetchone() is None


def test_identity_hmac_remains_bound_to_vault_key_when_key_check_is_replaced(server):
    app, _client, settings, _clock = server
    before = persisted(app)
    replacement = b"x" * 32
    settings.key_file.write_bytes(replacement)
    check = hmac.new(replacement, b"larenor-vault-key-check-v1", hashlib.sha256).hexdigest()
    with app.state.core.db.transaction() as connection:
        connection.execute("UPDATE metadata SET value=? WHERE key='key_check'", (check,))
    with pytest.raises(StartupError, match="^invalid_core_context$"):
        create_app(settings)
    assert persisted(app) == before
