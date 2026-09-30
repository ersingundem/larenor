import sqlite3

from ..errors import StartupError


TABLE = """CREATE TABLE room_presence_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    revision INTEGER NOT NULL CHECK(revision >= 0),
    nonce BLOB NOT NULL,
    ciphertext BLOB NOT NULL)"""

SOURCE_TABLE = """CREATE TABLE room_presence_provider_source (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    revision INTEGER NOT NULL CHECK(revision >= 1),
    nonce BLOB NOT NULL,
    ciphertext BLOB NOT NULL)"""


def migrate_room_presence(connection):
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='room_presence_schema'"
        ).fetchone()
        existing = connection.execute(
            "SELECT name,type,sql FROM sqlite_master WHERE name IN "
            "('room_presence_state','room_presence_provider_source')"
        ).fetchall()
        by_name = {row["name"]: row for row in existing}
        if marker is None:
            if existing:
                raise ValueError("unexpected_room_presence_table")
            connection.execute(TABLE)
            connection.execute(SOURCE_TABLE)
            connection.execute(
                "INSERT INTO metadata VALUES('room_presence_schema','2')"
            )
        elif marker["value"] == "1":
            state = by_name.get("room_presence_state")
            if (
                len(existing) != 1
                or state is None
                or state["type"] != "table"
                or " ".join(state["sql"].split()) != " ".join(TABLE.split())
            ):
                raise ValueError("invalid_room_presence_schema")
            connection.execute(SOURCE_TABLE)
            connection.execute(
                "UPDATE metadata SET value='2' WHERE key='room_presence_schema'"
            )
        elif (
            marker["value"] != "2"
            or set(by_name) != {
                "room_presence_state", "room_presence_provider_source"
            }
            or by_name["room_presence_state"]["type"] != "table"
            or by_name["room_presence_provider_source"]["type"] != "table"
            or " ".join(by_name["room_presence_state"]["sql"].split())
            != " ".join(TABLE.split())
            or " ".join(by_name["room_presence_provider_source"]["sql"].split())
            != " ".join(SOURCE_TABLE.split())
        ):
            raise ValueError("invalid_room_presence_schema")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("room_presence_storage_invalid") from None
