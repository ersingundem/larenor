import sqlite3

from ..errors import StartupError

MAX_RECEIPTS = 1024
INDEX = "CREATE INDEX bounded_transfer_resource_history ON bounded_transfer_receipts(resource_id,created_at DESC,request_id DESC)"

CREATE = """CREATE TABLE bounded_transfer_receipts (
    request_id TEXT PRIMARY KEY CHECK(length(request_id)=32 AND request_id NOT GLOB '*[^0-9a-f]*'),
    actor_id TEXT NOT NULL, core_id TEXT NOT NULL, home_id TEXT NOT NULL,
    resource_id TEXT NOT NULL, envelope_hash TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('accepted','completed','interrupted')),
    trace_id TEXT NOT NULL, content_length INTEGER NOT NULL CHECK(content_length BETWEEN 0 AND 262144),
    sha256 TEXT NOT NULL, content_type TEXT NOT NULL,
    service_revision INTEGER NOT NULL CHECK(service_revision>0),
    created_at REAL NOT NULL, updated_at REAL NOT NULL,
    authentication_tag TEXT NOT NULL
)"""


def _exact_schema(connection):
    objects = {
        (row["type"], row["name"]): row["sql"]
        for row in connection.execute(
            "SELECT type,name,sql FROM sqlite_master WHERE tbl_name='bounded_transfer_receipts'"
        )
    }
    if objects != {
        ("table", "bounded_transfer_receipts"): CREATE,
        ("index", "sqlite_autoindex_bounded_transfer_receipts_1"): None,
        ("index", "bounded_transfer_resource_history"): INDEX,
    }:
        raise ValueError("invalid_schema")
    columns = [
        (row["name"], row["type"], row["notnull"], row["dflt_value"], row["pk"])
        for row in connection.execute("PRAGMA table_info(bounded_transfer_receipts)")
    ]
    expected = [
        ("request_id", "TEXT", 0, None, 1),
        ("actor_id", "TEXT", 1, None, 0),
        ("core_id", "TEXT", 1, None, 0),
        ("home_id", "TEXT", 1, None, 0),
        ("resource_id", "TEXT", 1, None, 0),
        ("envelope_hash", "TEXT", 1, None, 0),
        ("state", "TEXT", 1, None, 0),
        ("trace_id", "TEXT", 1, None, 0),
        ("content_length", "INTEGER", 1, None, 0),
        ("sha256", "TEXT", 1, None, 0),
        ("content_type", "TEXT", 1, None, 0),
        ("service_revision", "INTEGER", 1, None, 0),
        ("created_at", "REAL", 1, None, 0),
        ("updated_at", "REAL", 1, None, 0),
        ("authentication_tag", "TEXT", 1, None, 0),
    ]
    if columns != expected:
        raise ValueError("invalid_schema")
    indexes = {
        (row["name"], row["unique"], row["origin"], row["partial"])
        for row in connection.execute("PRAGMA index_list(bounded_transfer_receipts)")
    }
    if indexes != {
        ("sqlite_autoindex_bounded_transfer_receipts_1", 1, "pk", 0),
        ("bounded_transfer_resource_history", 0, "c", 0),
    }:
        raise ValueError("invalid_schema")
    parts = [
        (row["name"], row["desc"], row["coll"], row["key"])
        for row in connection.execute("PRAGMA index_xinfo(bounded_transfer_resource_history)")
    ]
    if parts != [
        ("resource_id", 0, "BINARY", 1),
        ("created_at", 1, "BINARY", 1),
        ("request_id", 1, "BINARY", 1),
        (None, 0, "BINARY", 0),
    ]:
        raise ValueError("invalid_schema")


def migrate(connection):
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='bounded_transfer_schema'"
        ).fetchone()
        found = connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='bounded_transfer_receipts'"
        ).fetchone()
        if marker is None:
            if found is not None:
                raise ValueError("partial_schema")
            connection.execute(CREATE)
            connection.execute(INDEX)
            connection.execute("INSERT INTO metadata VALUES('bounded_transfer_schema','1')")
        elif marker["value"] != "1" or found is None:
            raise ValueError("invalid_schema")
        _exact_schema(connection)
    except (sqlite3.Error, ValueError, TypeError):
        raise StartupError("bounded_transfer_storage_invalid") from None
