"""Additive encrypted preparation history; independent of expiring previews."""

import sqlite3

from ..errors import StartupError


_COLUMNS = (
    ("id", "TEXT", 0, None, 1),
    ("sequence", "INTEGER", 1, None, 0),
    ("revision", "INTEGER", 1, None, 0),
    ("state", "TEXT", 1, None, 0),
    ("actor_id", "TEXT", 1, None, 0),
    ("actor_revision", "INTEGER", 1, None, 0),
    ("family_id", "TEXT", 1, None, 0),
    ("request_id", "TEXT", 1, None, 0),
    ("created_at", "INTEGER", 1, None, 0),
    ("updated_at", "INTEGER", 1, None, 0),
    ("cancelled_by", "TEXT", 0, None, 0),
    ("nonce", "BLOB", 1, None, 0),
    ("ciphertext", "BLOB", 1, None, 0),
)


def _verify_schema(connection):
    columns = tuple(tuple(row) for row in connection.execute(
        "SELECT name,type,\"notnull\",dflt_value,pk FROM pragma_table_info('media_preparations')"))
    if columns != _COLUMNS:
        raise StartupError("media_preparations_schema_unsupported")
    unique = set()
    state_index = False
    for index in connection.execute("PRAGMA index_list(media_preparations)"):
        fields = tuple(row[0] for row in connection.execute(
            "SELECT name FROM pragma_index_info(?) ORDER BY seqno", (index["name"],)))
        if index["unique"] and not index["partial"]:
            unique.add(fields)
        if index["name"] == "media_preparations_state":
            state_index = fields == ("state", "sequence") and not index["unique"] and not index["partial"]
    if unique != {("id",), ("sequence",), ("actor_id", "request_id")} or not state_index:
        raise StartupError("media_preparations_schema_unsupported")


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
    # An empty table cannot exercise record decoding. Validate its columns and
    # uniqueness guarantees before accepting any current-schema installation.
    _verify_schema(connection)
