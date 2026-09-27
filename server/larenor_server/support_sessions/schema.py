import sqlite3

from ..errors import StartupError


MAX_SESSIONS = 64
MAX_EVENTS = 1024

SESSIONS = """CREATE TABLE support_sessions (
    id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, family_id TEXT NOT NULL,
    core_id TEXT NOT NULL, home_id TEXT NOT NULL,
    request_key TEXT NOT NULL, supporter_id TEXT NOT NULL, supporter_name TEXT NOT NULL,
    permissions_json TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
    revision INTEGER NOT NULL, state TEXT NOT NULL CHECK(state IN ('active','revoked')),
    expires_at REAL NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
    record_tag TEXT NOT NULL, UNIQUE(owner_id,family_id,core_id,home_id,request_key))"""

EVENTS = """CREATE TABLE support_session_events (
    id TEXT PRIMARY KEY, session_id TEXT NOT NULL, permission TEXT NOT NULL,
    outcome TEXT NOT NULL CHECK(outcome IN ('allowed','denied')),
    created_at REAL NOT NULL, record_tag TEXT NOT NULL,
    FOREIGN KEY(session_id) REFERENCES support_sessions(id) ON DELETE CASCADE)"""


def migrate_support_sessions(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='support_session_schema'"
        ).fetchone()
        sessions = connection.execute(
            "SELECT type,sql FROM sqlite_master WHERE name='support_sessions'"
        ).fetchone()
        events = connection.execute(
            "SELECT type,sql FROM sqlite_master WHERE name='support_session_events'"
        ).fetchone()
        if marker is None:
            if sessions is not None or events is not None:
                raise ValueError("unmarked_support_sessions")
            connection.execute(SESSIONS)
            connection.execute(EVENTS)
            connection.execute("INSERT INTO metadata VALUES('support_session_schema','1')")
        elif (
            marker["value"] != "1"
            or sessions is None
            or events is None
            or sessions["type"] != "table"
            or events["type"] != "table"
            or " ".join(sessions["sql"].split()) != " ".join(SESSIONS.split())
            or " ".join(events["sql"].split()) != " ".join(EVENTS.split())
        ):
            raise ValueError("invalid_support_session_schema")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("support_session_storage_invalid") from None
