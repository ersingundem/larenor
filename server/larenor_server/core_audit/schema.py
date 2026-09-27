"""Additive storage schema for the bounded Core audit integrity chain."""

from __future__ import annotations

import sqlite3


MARKER_KEY = "core_audit_schema"
SCHEMA_VERSION = "1"
MAX_SOURCE_ROWS = 10_000
SOURCES = ("admin", "home_resource", "service")
MAX_ENTRIES = MAX_SOURCE_ROWS * len(SOURCES)
ZERO_HASH = "0" * 64

TABLES = {
    "core_audit_chain": """CREATE TABLE core_audit_chain (
        sequence INTEGER PRIMARY KEY CHECK(sequence > 0),
        kind TEXT NOT NULL CHECK(kind IN ('baseline','append')),
        source TEXT NOT NULL CHECK(source IN ('admin','home_resource','service')),
        source_id INTEGER NOT NULL CHECK(source_id > 0),
        payload_hash TEXT NOT NULL,
        previous_hash TEXT NOT NULL,
        entry_hash TEXT NOT NULL)""",
    "core_audit_state": """CREATE TABLE core_audit_state (
        singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
        chain_id TEXT NOT NULL,
        sequence INTEGER NOT NULL CHECK(sequence >= 0),
        head_hash TEXT NOT NULL,
        authentication_tag TEXT NOT NULL)""",
}


def objects(connection: sqlite3.Connection) -> dict[str, sqlite3.Row]:
    """Return only objects owned by this additive schema, with hard bounds."""

    where = "name GLOB 'core_audit_*' OR tbl_name IN ('core_audit_chain','core_audit_state')"
    count, longest_name, longest_sql = connection.execute(
        "SELECT COUNT(*),COALESCE(MAX(length(CAST(name AS BLOB))),0),"
        "COALESCE(MAX(length(CAST(sql AS BLOB))),0) FROM sqlite_master WHERE " + where
    ).fetchone()
    if count > len(TABLES) or longest_name > 128 or longest_sql > 2048:
        raise ValueError("invalid_core_audit_schema")
    return {
        row["name"]: row
        for row in connection.execute(
            "SELECT name,type,sql FROM sqlite_master WHERE " + where
        )
    }


def validate_schema(connection: sqlite3.Connection) -> None:
    marker = connection.execute(
        "SELECT typeof(value)='text' AND value=? FROM metadata WHERE key=?",
        (SCHEMA_VERSION, MARKER_KEY),
    ).fetchone()
    actual = objects(connection)
    if (
        marker is None
        or marker[0] != 1
        or set(actual) != set(TABLES)
        or any(
            row["type"] != "table"
            or " ".join(row["sql"].split()) != " ".join(TABLES[name].split())
            for name, row in actual.items()
        )
    ):
        raise ValueError("invalid_core_audit_schema")
