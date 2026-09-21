import sqlite3

from ..errors import StartupError


TABLE = """CREATE TABLE camera_visual_sensor_rules (
    id TEXT PRIMARY KEY,
    revision INTEGER NOT NULL CHECK(revision > 0),
    rule_json TEXT NOT NULL,
    actor_id TEXT NOT NULL,
    family_id TEXT NOT NULL,
    updated_at REAL NOT NULL,
    envelope_tag TEXT NOT NULL
)"""


def migrate_camera_visual_sensors(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='camera_visual_sensor_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,sql FROM sqlite_master "
            "WHERE name='camera_visual_sensor_rules'"
        ).fetchall()
        if marker is None:
            if rows:
                raise ValueError("unmarked_camera_visual_sensor_store")
            connection.execute(TABLE)
            connection.execute(
                "INSERT INTO metadata VALUES('camera_visual_sensor_schema','1')"
            )
            return
        if (
            marker["value"] != "1"
            or len(rows) != 1
            or rows[0]["type"] != "table"
            or " ".join(rows[0]["sql"].split()) != " ".join(TABLE.split())
        ):
            raise ValueError("invalid_camera_visual_sensor_store")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("camera_visual_sensor_storage_invalid") from None
