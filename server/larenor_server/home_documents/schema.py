import sqlite3

from ..errors import StartupError

TABLE = """CREATE TABLE home_document_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    revision INTEGER NOT NULL CHECK(revision >= 0),
    nonce BLOB NOT NULL,
    ciphertext BLOB NOT NULL)"""


def migrate_home_documents(connection):
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='home_documents_schema'"
        ).fetchone()
        existing = connection.execute(
            "SELECT name,type,sql FROM sqlite_master WHERE name='home_document_state'"
        ).fetchall()
        if marker is None:
            if existing:
                raise ValueError("unexpected_home_document_table")
            connection.execute(TABLE)
            connection.execute(
                "INSERT INTO metadata VALUES('home_documents_schema','1')"
            )
        elif (
            marker["value"] != "1"
            or len(existing) != 1
            or existing[0]["type"] != "table"
            or " ".join(existing[0]["sql"].split()) != " ".join(TABLE.split())
        ):
            raise ValueError("invalid_home_document_schema")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("home_document_storage_invalid") from None
