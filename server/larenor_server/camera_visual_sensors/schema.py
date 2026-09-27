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

RUNTIME_TABLE = """CREATE TABLE camera_visual_sensor_runtime (
    singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
    runtime_json TEXT NOT NULL,
    capability_json TEXT NOT NULL,
    envelope_tag TEXT NOT NULL,
    updated_at REAL NOT NULL
)"""


def migrate_camera_visual_sensors(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='camera_visual_sensor_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,sql FROM sqlite_master "
            "WHERE name IN ('camera_visual_sensor_rules','camera_visual_sensor_runtime') "
            "ORDER BY name"
        ).fetchall()
        if marker is None:
            if rows:
                raise ValueError("unmarked_camera_visual_sensor_store")
            connection.execute(TABLE)
            connection.execute(RUNTIME_TABLE)
            connection.execute(
                "INSERT INTO metadata VALUES('camera_visual_sensor_schema','2')"
            )
            return
        if marker["value"] == "1":
            if (
                len(rows) != 1
                or rows[0]["name"] != "camera_visual_sensor_rules"
                or rows[0]["type"] != "table"
                or " ".join(rows[0]["sql"].split()) != " ".join(TABLE.split())
            ):
                raise ValueError("invalid_camera_visual_sensor_store")
            connection.execute(RUNTIME_TABLE)
            connection.execute(
                "UPDATE metadata SET value='2' "
                "WHERE key='camera_visual_sensor_schema'"
            )
            return
        if (
            marker["value"] != "2"
            or len(rows) != 2
            or rows[0]["name"] != "camera_visual_sensor_rules"
            or rows[1]["name"] != "camera_visual_sensor_runtime"
            or rows[0]["type"] != "table"
            or rows[1]["type"] != "table"
            or " ".join(rows[0]["sql"].split()) != " ".join(TABLE.split())
            or " ".join(rows[1]["sql"].split()) != " ".join(RUNTIME_TABLE.split())
        ):
            raise ValueError("invalid_camera_visual_sensor_store")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("camera_visual_sensor_storage_invalid") from None
