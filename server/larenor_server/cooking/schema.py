import sqlite3

from ..errors import StartupError


TABLE = """CREATE TABLE cooking_sessions (
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    recipe_id TEXT NOT NULL,
    recipe_revision INTEGER NOT NULL CHECK(recipe_revision > 0),
    revision INTEGER NOT NULL CHECK(revision > 0),
    title TEXT NOT NULL,
    steps_json TEXT NOT NULL,
    current_step INTEGER NOT NULL CHECK(current_step >= 0),
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL)"""
ACCOUNT_INDEX = (
    "CREATE INDEX cooking_sessions_account ON "
    "cooking_sessions(account_id, updated_at DESC, id)"
)


def migrate_cooking_sessions(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='cooking_session_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name GLOB 'cooking_sessions*' OR tbl_name='cooking_sessions'"
        ).fetchall()
        by_name = {row["name"]: row for row in rows}
        if marker is None:
            if by_name:
                raise ValueError("unmarked_cooking_sessions")
            connection.execute(TABLE)
            connection.execute(ACCOUNT_INDEX)
            connection.execute(
                "INSERT INTO metadata VALUES('cooking_session_schema','1')"
            )
            return
        table = by_name.pop("cooking_sessions", None)
        primary = by_name.pop("sqlite_autoindex_cooking_sessions_1", None)
        account = by_name.pop("cooking_sessions_account", None)
        if (
            marker["value"] != "1"
            or by_name
            or table is None
            or table["type"] != "table"
            or " ".join(table["sql"].split()) != " ".join(TABLE.split())
            or primary is None
            or primary["type"] != "index"
            or primary["sql"] is not None
            or account is None
            or account["type"] != "index"
            or " ".join(account["sql"].split()) != " ".join(ACCOUNT_INDEX.split())
        ):
            raise ValueError("invalid_cooking_sessions")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("invalid_cooking_session_storage") from None
