"""SQLite schema for the single normal irrigation source binding."""

import sqlite3


SCHEMA_VERSION = "1"


def migrate_irrigation_source(connection: sqlite3.Connection) -> None:
    row = connection.execute(
        "SELECT value FROM metadata WHERE key='irrigation_source_schema'"
    ).fetchone()
    if row is not None and row["value"] != SCHEMA_VERSION:
        raise ValueError("invalid_irrigation_source_schema")
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS irrigation_source (
            singleton INTEGER PRIMARY KEY CHECK(singleton=1),
            revision INTEGER NOT NULL CHECK(revision > 0),
            payload_json TEXT NOT NULL,
            envelope_tag TEXT NOT NULL
        )
        """
    )
    connection.execute(
        "INSERT OR REPLACE INTO metadata(key,value) VALUES"
        "('irrigation_source_schema',?)",
        (SCHEMA_VERSION,),
    )
