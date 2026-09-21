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
"""


def migrate_room_comfort(connection: sqlite3.Connection) -> None:
    connection.executescript(DDL)
    connection.execute(
        "INSERT OR IGNORE INTO room_comfort_state(singleton,plan_id) VALUES(1,NULL)"
    )
