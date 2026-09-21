"""Strict persistent schema for F58 e-paper mappings and delivery receipts."""

import sqlite3

from ..errors import StartupError

TABLES = {
    "epaper_devices": """CREATE TABLE epaper_devices (
        device_id TEXT PRIMARY KEY, core_id TEXT NOT NULL, home_id TEXT NOT NULL,
        owner_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0),
        active INTEGER NOT NULL CHECK(active IN (0,1)), name TEXT NOT NULL,
        configuration TEXT NOT NULL, snapshot TEXT, verified_digest TEXT,
        updated_at REAL NOT NULL, authentication_tag TEXT NOT NULL)""",
    "epaper_previews": """CREATE TABLE epaper_previews (
        request_id TEXT PRIMARY KEY, device_id TEXT NOT NULL, actor_id TEXT NOT NULL,
        session_family_id TEXT NOT NULL, action TEXT NOT NULL CHECK(action='refresh'),
        device_revision INTEGER NOT NULL CHECK(device_revision > 0),
        layout_revision INTEGER NOT NULL CHECK(layout_revision > 0),
        expires_at REAL NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','cancelled','published')),
        command_digest TEXT NOT NULL, authentication_tag TEXT NOT NULL,
        FOREIGN KEY(device_id) REFERENCES epaper_devices(device_id) ON DELETE CASCADE)""",
    "epaper_polls": """CREATE TABLE epaper_polls (
        request_id TEXT PRIMARY KEY, device_id TEXT NOT NULL,
        device_revision INTEGER NOT NULL CHECK(device_revision > 0),
        render_digest TEXT NOT NULL, byte_length INTEGER NOT NULL CHECK(byte_length > 0),
        frame_count INTEGER NOT NULL CHECK(frame_count > 0),
        status TEXT NOT NULL CHECK(status IN ('pending','partial','verified')),
        received_frames INTEGER NOT NULL CHECK(received_frames >= 0),
        authentication_tag TEXT NOT NULL,
        FOREIGN KEY(device_id) REFERENCES epaper_devices(device_id) ON DELETE CASCADE)""",
}


def migrate_epaper_snapshots(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='epaper_snapshot_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name GLOB 'epaper_*' OR tbl_name GLOB 'epaper_*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["type"] == "table"}
        implicit = {
            row["name"] for row in rows if row["type"] == "index" and row["sql"] is None
        }
        if marker is None:
            if actual or implicit:
                raise ValueError("unmarked_epaper_schema")
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata VALUES('epaper_snapshot_schema','1')"
            )
            return
        if marker["value"] != "1" or set(actual) != set(TABLES):
            raise ValueError("invalid_epaper_schema")
        for name, statement in TABLES.items():
            if (
                actual[name]["type"] != "table"
                or " ".join(actual[name]["sql"].split())
                != " ".join(statement.split())
            ):
                raise ValueError("invalid_epaper_schema")
        expected_indexes = {
            "sqlite_autoindex_epaper_devices_1",
            "sqlite_autoindex_epaper_previews_1",
            "sqlite_autoindex_epaper_polls_1",
        }
        if implicit != expected_indexes:
            raise ValueError("invalid_epaper_indexes")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("epaper_snapshot_storage_invalid") from None
