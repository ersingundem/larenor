import sqlite3

from ..errors import StartupError


MAX_GRANTS = 128
MAX_PREVIEWS = 256

GRANTS = """CREATE TABLE mcp_gateway_grants (
    id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, family_id TEXT NOT NULL,
    request_key TEXT NOT NULL, client_id TEXT NOT NULL, client_name TEXT NOT NULL,
    tools_json TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
    revision INTEGER NOT NULL, state TEXT NOT NULL CHECK(state IN ('active','revoked')),
    expires_at REAL NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
    record_tag TEXT NOT NULL, UNIQUE(owner_id,family_id,request_key))"""

PREVIEWS = """CREATE TABLE mcp_gateway_previews (
    id TEXT PRIMARY KEY, grant_id TEXT NOT NULL, request_key TEXT NOT NULL,
    tool_id TEXT NOT NULL CHECK(tool_id='home.note.create'), title TEXT NOT NULL,
    revision INTEGER NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','confirmed')),
    created_at REAL NOT NULL, updated_at REAL NOT NULL, record_tag TEXT NOT NULL,
    UNIQUE(grant_id,request_key),
    FOREIGN KEY(grant_id) REFERENCES mcp_gateway_grants(id) ON DELETE CASCADE)"""


def migrate_mcp_gateway(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='mcp_gateway_schema'"
        ).fetchone()
        grants = connection.execute(
            "SELECT type,sql FROM sqlite_master WHERE name='mcp_gateway_grants'"
        ).fetchone()
        previews = connection.execute(
            "SELECT type,sql FROM sqlite_master WHERE name='mcp_gateway_previews'"
        ).fetchone()
        if marker is None:
            if grants is not None or previews is not None:
                raise ValueError("unmarked_mcp_gateway")
            connection.execute(GRANTS)
            connection.execute(PREVIEWS)
            connection.execute("INSERT INTO metadata VALUES('mcp_gateway_schema','1')")
        elif (
            marker["value"] != "1"
            or grants is None
            or previews is None
            or grants["type"] != "table"
            or previews["type"] != "table"
            or " ".join(grants["sql"].split()) != " ".join(GRANTS.split())
            or " ".join(previews["sql"].split()) != " ".join(PREVIEWS.split())
        ):
            raise ValueError("invalid_mcp_gateway_schema")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("mcp_gateway_storage_invalid") from None
