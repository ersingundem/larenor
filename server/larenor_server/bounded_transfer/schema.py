import sqlite3

from ..errors import StartupError

MAX_RECEIPTS = 1024

CREATE = """CREATE TABLE bounded_transfer_receipts (
    request_id TEXT PRIMARY KEY CHECK(length(request_id)=32 AND request_id NOT GLOB '*[^0-9a-f]*'),
    actor_id TEXT NOT NULL, core_id TEXT NOT NULL, home_id TEXT NOT NULL,
    resource_id TEXT NOT NULL, request_hash TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('accepted','completed','interrupted')),
    trace_id TEXT NOT NULL, content_length INTEGER NOT NULL CHECK(content_length BETWEEN 0 AND 262144),
    sha256 TEXT NOT NULL, content_type TEXT NOT NULL,
    service_revision INTEGER NOT NULL CHECK(service_revision>0),
    created_at REAL NOT NULL, updated_at REAL NOT NULL,
    authentication_tag TEXT NOT NULL
)"""


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
            connection.execute(
                "CREATE INDEX bounded_transfer_resource_history ON bounded_transfer_receipts(resource_id,created_at DESC,request_id DESC)"
            )
            connection.execute("INSERT INTO metadata VALUES('bounded_transfer_schema','1')")
        elif marker["value"] != "1" or found is None:
            raise ValueError("invalid_schema")
    except (sqlite3.Error, ValueError, TypeError):
        raise StartupError("bounded_transfer_storage_invalid") from None
