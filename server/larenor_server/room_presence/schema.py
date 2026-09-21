import sqlite3

from ..errors import StartupError


TABLE = """CREATE TABLE room_presence_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    revision INTEGER NOT NULL CHECK(revision >= 0),
    nonce BLOB NOT NULL,
    ciphertext BLOB NOT NULL)"""


def migrate_room_presence(connection):
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='room_presence_schema'"
        ).fetchone()
        existing = connection.execute(
            "SELECT name,type,sql FROM sqlite_master WHERE name='room_presence_state'"
        ).fetchall()
        if marker is None:
            if existing:
                raise ValueError("unexpected_room_presence_table")
            connection.execute(TABLE)
            connection.execute(
                "INSERT INTO metadata VALUES('room_presence_schema','1')"
            )
        elif (
            marker["value"] != "1"
            or len(existing) != 1
            or existing[0]["type"] != "table"
            or " ".join(existing[0]["sql"].split()) != " ".join(TABLE.split())
        ):
            raise ValueError("invalid_room_presence_schema")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("room_presence_storage_invalid") from None
