"""Exact additive schema for encrypted, resource-bound product blobs."""

import sqlite3

from ..errors import StartupError


MAX_OBJECTS = 512
MAX_UPLOADS = 1024

OBJECTS = """CREATE TABLE bounded_blob_objects (
    resource_id TEXT PRIMARY KEY REFERENCES home_resource_records(id) ON DELETE CASCADE,
    core_id TEXT NOT NULL, home_id TEXT NOT NULL,
    request_id TEXT NOT NULL UNIQUE,
    service_revision INTEGER NOT NULL CHECK(service_revision>0),
    content_length INTEGER NOT NULL CHECK(content_length BETWEEN 1 AND 262144),
    sha256 TEXT NOT NULL, content_type TEXT NOT NULL,
    created_at REAL NOT NULL, updated_at REAL NOT NULL,
    nonce BLOB NOT NULL, ciphertext BLOB NOT NULL,
    authentication_tag TEXT NOT NULL
)"""

UPLOADS = """CREATE TABLE bounded_blob_uploads (
    request_id TEXT PRIMARY KEY CHECK(length(request_id)=32 AND request_id NOT GLOB '*[^0-9a-f]*'),
    actor_id TEXT NOT NULL, core_id TEXT NOT NULL, home_id TEXT NOT NULL,
    resource_id TEXT NOT NULL REFERENCES home_resource_records(id) ON DELETE CASCADE,
    envelope_hash TEXT NOT NULL,
    service_revision INTEGER NOT NULL CHECK(service_revision>0),
    content_length INTEGER NOT NULL CHECK(content_length BETWEEN 1 AND 262144),
    sha256 TEXT NOT NULL, content_type TEXT NOT NULL,
    created_at REAL NOT NULL, updated_at REAL NOT NULL,
    authentication_tag TEXT NOT NULL
)"""

UPLOAD_INDEX = (
    "CREATE INDEX bounded_blob_resource_uploads ON "
    "bounded_blob_uploads(resource_id,created_at DESC,request_id DESC)"
)


def _normalized(value):
    return None if value is None else " ".join(value.split())


def _exact_schema(connection):
    objects = {
        (row["type"], row["name"]): _normalized(row["sql"])
        for row in connection.execute(
            "SELECT type,name,sql FROM sqlite_master "
            "WHERE tbl_name IN ('bounded_blob_objects','bounded_blob_uploads')"
        )
    }
    expected = {
        ("table", "bounded_blob_objects"): _normalized(OBJECTS),
        ("index", "sqlite_autoindex_bounded_blob_objects_1"): None,
        ("index", "sqlite_autoindex_bounded_blob_objects_2"): None,
        ("table", "bounded_blob_uploads"): _normalized(UPLOADS),
        ("index", "sqlite_autoindex_bounded_blob_uploads_1"): None,
        ("index", "bounded_blob_resource_uploads"): _normalized(UPLOAD_INDEX),
    }
    if objects != expected:
        raise ValueError("invalid_schema")
    foreign = connection.execute(
        "PRAGMA foreign_key_list(bounded_blob_objects)"
    ).fetchall()
    upload_foreign = connection.execute(
        "PRAGMA foreign_key_list(bounded_blob_uploads)"
    ).fetchall()
    for rows in (foreign, upload_foreign):
        if len(rows) != 1:
            raise ValueError("invalid_schema")
        row = rows[0]
        if (
            row["table"] != "home_resource_records"
            or row["from"] != "resource_id"
            or row["to"] != "id"
            or row["on_delete"] != "CASCADE"
        ):
            raise ValueError("invalid_schema")


def migrate(connection):
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='bounded_blob_schema'"
        ).fetchone()
        found = connection.execute(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' "
            "AND name IN ('bounded_blob_objects','bounded_blob_uploads')"
        ).fetchone()[0]
        if marker is None:
            if found:
                raise ValueError("partial_schema")
            connection.execute(OBJECTS)
            connection.execute(UPLOADS)
            connection.execute(UPLOAD_INDEX)
            connection.execute(
                "INSERT INTO metadata VALUES('bounded_blob_schema','1')"
            )
        elif marker["value"] != "1" or found != 2:
            raise ValueError("invalid_schema")
        _exact_schema(connection)
    except (sqlite3.Error, ValueError, TypeError):
        raise StartupError("bounded_blob_storage_invalid") from None
