"""Additive encrypted preparation history; independent of expiring previews."""

import sqlite3

from ..errors import StartupError


def migrate_media_preparations(connection: sqlite3.Connection) -> None:
    marker = connection.execute("SELECT value FROM metadata WHERE key='media_preparations_schema'").fetchone()
    tables = {row[0] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'media_preparation%'")}
    if marker is None:
        if tables:
            raise StartupError("media_preparations_schema_unsupported")
        connection.execute("""CREATE TABLE media_preparations (
            id TEXT PRIMARY KEY,
            sequence INTEGER NOT NULL UNIQUE CHECK(sequence > 0),
            revision INTEGER NOT NULL CHECK(revision IN (1,2)),
            state TEXT NOT NULL CHECK(state IN ('prepared','cancelled')),
            actor_id TEXT NOT NULL,
            actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
            family_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            cancelled_by TEXT,
            nonce BLOB NOT NULL,
            ciphertext BLOB NOT NULL,
            UNIQUE(actor_id,request_id)
        )""")
        connection.execute("CREATE INDEX media_preparations_state ON media_preparations(state,sequence)")
        connection.execute("INSERT INTO metadata(key,value) VALUES('media_preparations_schema','1')")
    elif marker["value"] != "1" or tables != {"media_preparations"}:
        raise StartupError("media_preparations_schema_unsupported")
