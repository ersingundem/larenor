import sqlite3

from ..errors import StartupError


TABLE = """CREATE TABLE jellyfin_track_preferences (
    owner_id TEXT PRIMARY KEY,
    revision INTEGER NOT NULL CHECK(revision > 0),
    audio_language TEXT,
    subtitle_language TEXT,
    updated_at REAL NOT NULL,
    authentication_tag TEXT NOT NULL,
    FOREIGN KEY(owner_id) REFERENCES users(id) ON DELETE CASCADE)"""


def migrate_jellyfin_track_preferences(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='jellyfin_track_preferences_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name='jellyfin_track_preferences' "
            "OR tbl_name='jellyfin_track_preferences'"
        ).fetchall()
        actual = {
            row["name"]: row
            for row in rows
            if not (row["type"] == "index" and row["sql"] is None)
        }
        implicit = [
            row
            for row in rows
            if row["type"] == "index" and row["sql"] is None
        ]
        if marker is None:
            if actual or implicit:
                raise ValueError("unmarked_jellyfin_preference_storage")
            connection.execute(TABLE)
            connection.execute(
                "INSERT INTO metadata VALUES('jellyfin_track_preferences_schema','1')"
            )
            return
        row = actual.get("jellyfin_track_preferences")
        if (
            marker["value"] != "1"
            or set(actual) != {"jellyfin_track_preferences"}
            or row["type"] != "table"
            or " ".join(row["sql"].split()) != " ".join(TABLE.split())
            or len(implicit) != 1
        ):
            raise ValueError("invalid_jellyfin_preference_storage")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("jellyfin_track_preferences_storage_invalid") from None
