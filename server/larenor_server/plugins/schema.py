"""Additive preview-only schema; job execution has no database contract yet."""

import sqlite3

from ..errors import StartupError


TABLE = """CREATE TABLE plugin_previews (
    id TEXT PRIMARY KEY,
    revision INTEGER NOT NULL CHECK(revision = 1),
    actor_id TEXT NOT NULL REFERENCES users(id),
    actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
    family_id TEXT NOT NULL REFERENCES session_families(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    nonce BLOB NOT NULL,
    ciphertext BLOB NOT NULL,
    CHECK(expires_at = created_at + 600)
)"""


def migrate_plugins(connection: sqlite3.Connection) -> None:
    marker = connection.execute("SELECT value FROM metadata WHERE key='plugins_schema'").fetchone()
    tables = {row[0] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'plugin_%'")}
    if marker is None:
        if tables:
            raise StartupError("plugins_schema_unsupported")
        connection.execute(TABLE)
        connection.execute("CREATE INDEX plugin_previews_expiry ON plugin_previews(expires_at)")
        connection.execute("INSERT INTO metadata(key,value) VALUES('plugins_schema','1')")
    elif marker["value"] != "1" or tables != {"plugin_previews"}:
        raise StartupError("plugins_schema_unsupported")
