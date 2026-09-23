import sqlite3

from ..errors import StartupError


MAX_RECORDS = 256
MAX_RECEIPTS = 4096
MAX_RECEIPTS_PER_ACCOUNT = 128
TABLES = {
    "media_language_preferences": """CREATE TABLE media_language_preferences (
        owner_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        revision INTEGER NOT NULL CHECK(revision > 0),
        nonce BLOB NOT NULL,
        ciphertext BLOB NOT NULL)""",
    "media_language_preference_receipts": """CREATE TABLE media_language_preference_receipts (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        family_id TEXT NOT NULL,
        request_id TEXT NOT NULL,
        request_hash TEXT NOT NULL,
        nonce BLOB NOT NULL,
        ciphertext BLOB NOT NULL,
        UNIQUE(owner_id,family_id,request_id))""",
}


def migrate_media_language_preferences(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='media_language_preferences_schema'"
        ).fetchone()
        existing = {
            row["name"]: row
            for row in connection.execute(
                "SELECT name,type,sql FROM sqlite_master WHERE type='table' "
                "AND name GLOB 'media_language_preference*'"
            )
        }
        if marker is None:
            if existing:
                raise ValueError("unmarked_media_language_preference_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata VALUES('media_language_preferences_schema','1')"
            )
        elif marker["value"] != "1" or set(existing) != set(TABLES) or any(
            row["type"] != "table"
            or " ".join(row["sql"].split()) != " ".join(TABLES[name].split())
            for name, row in existing.items()
        ):
            raise ValueError("invalid_media_language_preference_storage")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("media_language_preference_storage_invalid") from None
