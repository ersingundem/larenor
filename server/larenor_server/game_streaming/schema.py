import sqlite3

from ..errors import StartupError


TABLES = {
    "game_stream_hosts": """CREATE TABLE game_stream_hosts (
        id TEXT PRIMARY KEY, registration_id TEXT NOT NULL UNIQUE,
        revision INTEGER NOT NULL CHECK(revision > 0), name TEXT NOT NULL,
        pairing_revision INTEGER NOT NULL CHECK(pairing_revision > 0),
        credential_digest TEXT NOT NULL, capabilities TEXT NOT NULL,
        active INTEGER NOT NULL CHECK(active IN (0,1)), created_at REAL NOT NULL,
        updated_at REAL NOT NULL, envelope_tag TEXT NOT NULL)""",
    "game_stream_sessions": """CREATE TABLE game_stream_sessions (
        id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, family_id TEXT NOT NULL,
        host_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0),
        request_key TEXT NOT NULL, request_hash TEXT NOT NULL,
        authority TEXT NOT NULL, expires_at REAL NOT NULL,
        state TEXT NOT NULL CHECK(state IN ('open','retired')),
        created_at REAL NOT NULL, envelope_tag TEXT NOT NULL,
        UNIQUE(owner_id,request_key),
        FOREIGN KEY(host_id) REFERENCES game_stream_hosts(id) ON DELETE RESTRICT)""",
    "game_stream_commands": """CREATE TABLE game_stream_commands (
        id TEXT PRIMARY KEY, session_id TEXT NOT NULL, request_key TEXT NOT NULL,
        request_hash TEXT NOT NULL, intent TEXT NOT NULL
            CHECK(intent IN ('wake','launch','stream','stop')),
        state TEXT NOT NULL CHECK(state IN ('authorized','verified','unknown','rejected')),
        result TEXT, readback_revision INTEGER, created_at REAL NOT NULL,
        completed_at REAL, envelope_tag TEXT NOT NULL,
        UNIQUE(session_id,request_key),
        FOREIGN KEY(session_id) REFERENCES game_stream_sessions(id) ON DELETE RESTRICT)""",
}


def migrate_game_streaming(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='game_stream_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,sql FROM sqlite_master WHERE name GLOB 'game_stream_*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["sql"] is not None}
        if marker is None:
            if actual:
                raise ValueError("unmarked_game_stream_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute("INSERT INTO metadata VALUES('game_stream_schema','1')")
            return
        if marker["value"] != "1" or set(actual) != set(TABLES) or any(
            row["type"] != "table"
            or " ".join(row["sql"].split()) != " ".join(TABLES[name].split())
            for name, row in actual.items()
        ):
            raise ValueError("invalid_game_stream_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("game_stream_storage_invalid") from None
