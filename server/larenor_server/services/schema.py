"""Additive, atomic schema extension called under the core initialization lock."""

import sqlite3

from ..errors import StartupError


TABLES = (
    """CREATE TABLE service_connections (
        id TEXT PRIMARY KEY,
        revision INTEGER NOT NULL CHECK(revision > 0),
        nonce BLOB NOT NULL,
        ciphertext BLOB NOT NULL
    )""",
    """CREATE TABLE service_audit (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        event TEXT NOT NULL,
        action TEXT NOT NULL CHECK(action IN ('create','update','delete','check')),
        status TEXT NOT NULL CHECK(status IN ('success','denied')),
        timestamp REAL NOT NULL,
        actor_id TEXT NOT NULL,
        target_id TEXT NOT NULL
    )""",
)


def migrate_services(connection: sqlite3.Connection) -> None:
    marker = connection.execute("SELECT value FROM metadata WHERE key='services_schema'").fetchone()
    tables = {row[0] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('service_connections','service_audit')")}
    if marker is None:
        if tables:
            raise StartupError("services_schema_unsupported")
        for statement in TABLES:
            connection.execute(statement)
        connection.execute("INSERT INTO metadata(key,value) VALUES('services_schema','1')")
    elif marker["value"] != "1" or tables != {"service_connections", "service_audit"}:
        raise StartupError("services_schema_unsupported")
