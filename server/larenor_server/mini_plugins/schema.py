import sqlite3

from ..errors import StartupError


CREATE = """CREATE TABLE mini_plugin_instances (
    id TEXT PRIMARY KEY, creator_id TEXT NOT NULL, family_id TEXT NOT NULL,
    request_key TEXT NOT NULL, core_id TEXT NOT NULL, home_id TEXT NOT NULL,
    template_id TEXT NOT NULL CHECK(template_id='home-resource-count'),
    display_name TEXT NOT NULL, revision INTEGER NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('running','stopped')),
    created_at REAL NOT NULL, updated_at REAL NOT NULL, record_tag TEXT NOT NULL,
    UNIQUE(creator_id,family_id,request_key))"""


def migrate_mini_plugins(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='mini_plugin_schema'"
        ).fetchone()
        row = connection.execute(
            "SELECT type,sql FROM sqlite_master WHERE name='mini_plugin_instances'"
        ).fetchone()
        if marker is None:
            if row is not None:
                raise ValueError("unmarked_mini_plugins")
            connection.execute(CREATE)
            connection.execute(
                "INSERT INTO metadata VALUES('mini_plugin_schema','1')"
            )
        elif (
            marker["value"] != "1"
            or row is None
            or row["type"] != "table"
            or " ".join(row["sql"].split()) != " ".join(CREATE.split())
        ):
            raise ValueError("invalid_mini_plugin_schema")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("mini_plugin_storage_invalid") from None
