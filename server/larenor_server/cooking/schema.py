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
    cancelled_at REAL,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL)"""
ACCOUNT_INDEX = (
    "CREATE INDEX cooking_sessions_account ON "
    "cooking_sessions(account_id, updated_at DESC, id)"
)
DEDUCTIONS_TABLE = """CREATE TABLE cooking_deductions (
    idempotency_key TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    receipt_json TEXT NOT NULL,
    created_at REAL NOT NULL,
    FOREIGN KEY(session_id) REFERENCES cooking_sessions(id))"""
DEDUCTIONS_ACCOUNT_INDEX = (
    "CREATE INDEX cooking_deductions_account ON "
    "cooking_deductions(account_id, created_at DESC, idempotency_key)"
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
            connection.execute(DEDUCTIONS_TABLE)
            connection.execute(DEDUCTIONS_ACCOUNT_INDEX)
            connection.execute(
                "INSERT INTO metadata VALUES('cooking_session_schema','3')"
            )
            return
        if marker["value"] == "1":
            legacy_table = by_name.get("cooking_sessions")
            legacy_index = by_name.get("cooking_sessions_account")
            if (
                legacy_table is None
                or legacy_table["type"] != "table"
                or legacy_index is None
                or legacy_index["type"] != "index"
            ):
                raise ValueError("invalid_cooking_sessions")
            connection.execute("DROP INDEX cooking_sessions_account")
            connection.execute(
                "ALTER TABLE cooking_sessions RENAME TO cooking_sessions_v1"
            )
            connection.execute(TABLE)
            connection.execute(
                "INSERT INTO cooking_sessions "
                "(id,account_id,recipe_id,recipe_revision,revision,title,steps_json,"
                "current_step,cancelled_at,created_at,updated_at) "
                "SELECT id,account_id,recipe_id,recipe_revision,revision,title,"
                "steps_json,current_step,NULL,created_at,updated_at "
                "FROM cooking_sessions_v1"
            )
            connection.execute("DROP TABLE cooking_sessions_v1")
            connection.execute(ACCOUNT_INDEX)
            connection.execute(DEDUCTIONS_TABLE)
            connection.execute(DEDUCTIONS_ACCOUNT_INDEX)
            connection.execute(
                "UPDATE metadata SET value='3' WHERE key='cooking_session_schema'"
            )
            rows = connection.execute(
                "SELECT name,type,tbl_name,sql FROM sqlite_master "
                "WHERE name GLOB 'cooking_sessions*' OR tbl_name='cooking_sessions'"
            ).fetchall()
            by_name = {row["name"]: row for row in rows}
        elif marker["value"] == "2":
            connection.execute(DEDUCTIONS_TABLE)
            connection.execute(DEDUCTIONS_ACCOUNT_INDEX)
            connection.execute(
                "UPDATE metadata SET value='3' WHERE key='cooking_session_schema'"
            )
        table = by_name.pop("cooking_sessions", None)
        primary = by_name.pop("sqlite_autoindex_cooking_sessions_1", None)
        account = by_name.pop("cooking_sessions_account", None)
        if (
            connection.execute(
                "SELECT value FROM metadata WHERE key='cooking_session_schema'"
            ).fetchone()["value"] != "3"
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
        deductions = connection.execute(
            "SELECT name,type,sql FROM sqlite_master "
            "WHERE name IN ('cooking_deductions','cooking_deductions_account')"
        ).fetchall()
        deductions_by_name = {row["name"]: row for row in deductions}
        deductions_table = deductions_by_name.get("cooking_deductions")
        deductions_index = deductions_by_name.get("cooking_deductions_account")
        if (
            len(deductions_by_name) != 2
            or deductions_table is None
            or deductions_table["type"] != "table"
            or " ".join(deductions_table["sql"].split())
            != " ".join(DEDUCTIONS_TABLE.split())
            or deductions_index is None
            or deductions_index["type"] != "index"
            or " ".join(deductions_index["sql"].split())
            != " ".join(DEDUCTIONS_ACCOUNT_INDEX.split())
        ):
            raise ValueError("invalid_cooking_deductions")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("invalid_cooking_session_storage") from None
