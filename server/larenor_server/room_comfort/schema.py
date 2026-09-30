import sqlite3

DDL = """
CREATE TABLE IF NOT EXISTS room_comfort_plans (
    id TEXT PRIMARY KEY,
    policy_json TEXT NOT NULL,
    plan_json TEXT NOT NULL,
    readbacks_json TEXT NOT NULL,
    actor_id TEXT NOT NULL,
    family_id TEXT NOT NULL,
    created_at REAL NOT NULL,
    envelope_tag TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS room_comfort_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    plan_id TEXT REFERENCES room_comfort_plans(id)
);
CREATE TABLE IF NOT EXISTS room_comfort_previews (
    id TEXT PRIMARY KEY,
    request_id TEXT NOT NULL UNIQUE,
    plan_id TEXT NOT NULL REFERENCES room_comfort_plans(id),
    actor_id TEXT NOT NULL,
    family_id TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    expires_at REAL NOT NULL,
    receipt_json TEXT,
    envelope_tag TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS room_comfort_dispatches (
    command_id TEXT PRIMARY KEY,
    preview_id TEXT NOT NULL REFERENCES room_comfort_previews(id),
    command_json TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('dispatching','completed')),
    result_json TEXT,
    reserved_at REAL NOT NULL,
    completed_at REAL,
    envelope_tag TEXT NOT NULL,
    CHECK((state='dispatching' AND result_json IS NULL AND completed_at IS NULL) OR
          (state='completed' AND result_json IS NOT NULL AND completed_at IS NOT NULL))
);
CREATE TABLE IF NOT EXISTS room_comfort_source (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    revision INTEGER NOT NULL CHECK(revision > 0),
    payload_json TEXT NOT NULL,
    envelope_tag TEXT NOT NULL
);
"""


def migrate_room_comfort(connection: sqlite3.Connection) -> None:
    # sqlite3.executescript() commits an active transaction before running the
    # script. Core migrations must remain part of the caller's single startup
    # transaction so a later schema failure rolls every new table back.
    for statement in DDL.split(";"):
        if sql := statement.strip():
            connection.execute(sql)
    connection.execute(
        "INSERT OR IGNORE INTO room_comfort_state(singleton,plan_id) VALUES(1,NULL)"
    )
