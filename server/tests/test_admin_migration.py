import sqlite3

import pytest

from larenor_server.app import create_app
from larenor_server.database import Database
from larenor_server.errors import StartupError

from conftest import auth, document, ready


def downgrade_to_known_v1(app):
    """Construct the shipped v1 schema, retaining credentials, vault and sessions."""
    with app.state.core.db.transaction() as connection:
        connection.execute("ALTER TABLE users DROP COLUMN disabled")
        connection.execute("ALTER TABLE users DROP COLUMN revision")
        connection.execute("DROP TABLE admin_audit")
        connection.execute("UPDATE metadata SET value='1' WHERE key='schema_version'")


def test_schema_v1_migrates_atomically_without_reset_or_key_rotation(server):
    app, client, settings, _clock = server
    pair = ready(server)
    assert client.put("/api/v1/vault", headers=auth(pair), json={"expectedRevision": 0, "document": document()}).status_code == 200
    with app.state.core.db.connection() as connection:
        before = dict(connection.execute("SELECT * FROM users").fetchone())
        ciphertext = bytes(connection.execute("SELECT ciphertext FROM vaults").fetchone()[0])
    key = settings.key_file.read_bytes()
    downgrade_to_known_v1(app)
    restored = create_app(settings)
    current = restored.state.core.auth.authenticate(pair["accessToken"])
    assert restored.state.core.vault.get(current)["document"] == document()
    assert settings.key_file.read_bytes() == key
    assert not restored.state.core.bootstrap_created
    assert not settings.effective_bootstrap_file.exists()
    with restored.state.core.db.connection() as connection:
        assert connection.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()[0] == "2"
        after = dict(connection.execute("SELECT * FROM users").fetchone())
        assert after["disabled"] == 0 and after["revision"] == 1
        for name in ["id", "username", "role", "password_hash", "must_change_password", "created_at"]:
            assert before[name] == after[name]
        assert bytes(connection.execute("SELECT ciphertext FROM vaults").fetchone()[0]) == ciphertext
    again = create_app(settings)
    assert again.state.core.admin.users(again.state.core.auth.authenticate(pair["accessToken"]))["users"][0]["revision"] == 1


def test_migration_failure_rolls_back_and_can_retry(server, monkeypatch):
    app, _client, settings, _clock = server
    ready(server)
    downgrade_to_known_v1(app)
    original = Database.migrate_v1
    def interrupted(connection):
        connection.execute("ALTER TABLE users ADD COLUMN disabled INTEGER NOT NULL DEFAULT 0")
        raise sqlite3.OperationalError("synthetic migration interruption")
    monkeypatch.setattr(Database, "migrate_v1", staticmethod(interrupted))
    with pytest.raises(StartupError, match="storage_initialization_failed"):
        create_app(settings)
    with app.state.core.db.connection() as connection:
        assert "disabled" not in [row["name"] for row in connection.execute("PRAGMA table_info(users)")]
        assert connection.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()[0] == "1"
    monkeypatch.setattr(Database, "migrate_v1", staticmethod(original))
    restored = create_app(settings)
    with restored.state.core.db.connection() as connection:
        assert connection.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()[0] == "2"


def test_wrong_key_never_runs_schema_migration(server, monkeypatch):
    app, _client, settings, _clock = server
    ready(server)
    downgrade_to_known_v1(app)
    settings.key_file.write_bytes(bytes([91]) * 32)
    def forbidden(_connection):
        pytest.fail("Wrong vault key reached migration")
    monkeypatch.setattr(Database, "migrate_v1", staticmethod(forbidden))
    with pytest.raises(StartupError, match="existing_database_invalid_or_wrong_key"):
        create_app(settings)
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()[0] == "1"
        assert "disabled" not in [row["name"] for row in connection.execute("PRAGMA table_info(users)")]
