import sqlite3

from ..errors import StartupError


MAX_DEVICES = 256
MAX_COMMANDS = 10000

TABLES = {
    "managed_tablets": """CREATE TABLE managed_tablets (
        id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, family_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 0),
        active INTEGER NOT NULL CHECK(active IN (0,1)),
        nonce BLOB NOT NULL, ciphertext BLOB NOT NULL,
        created_at REAL NOT NULL, updated_at REAL NOT NULL, last_seen_at REAL NOT NULL)""",
    "managed_tablet_commands": """CREATE TABLE managed_tablet_commands (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
        device_id TEXT NOT NULL, request_key TEXT NOT NULL, command TEXT NOT NULL,
        required_mode TEXT NOT NULL CHECK(required_mode IN ('standard','deviceOwner')),
        policy_revision INTEGER NOT NULL CHECK(policy_revision > 0),
        expires_at REAL NOT NULL,
        state TEXT NOT NULL CHECK(state IN ('pending','delivered','completed','expired')),
        result TEXT CHECK(result IS NULL OR result IN ('succeeded','denied','failed','unsupported','expired')),
        created_at REAL NOT NULL, delivered_at REAL, completed_at REAL,
        envelope_tag TEXT NOT NULL, UNIQUE(device_id,request_key),
        FOREIGN KEY(device_id) REFERENCES managed_tablets(id) ON DELETE CASCADE)""",
    "managed_tablet_events": """CREATE TABLE managed_tablet_events (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        audit_id TEXT NOT NULL UNIQUE,
        action TEXT NOT NULL CHECK(action IN ('registered','heartbeat','policy_updated','revoked','command_issued','command_delivered','command_completed','command_expired')),
        actor_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        command_id TEXT,
        occurred_at REAL NOT NULL,
        previous_hash TEXT NOT NULL,
        event_hash TEXT NOT NULL)""",
    "managed_tablet_audit_state": """CREATE TABLE managed_tablet_audit_state (
        id INTEGER PRIMARY KEY CHECK(id=1),
        event_count INTEGER NOT NULL CHECK(event_count > 0),
        last_hash TEXT NOT NULL,
        state_hash TEXT NOT NULL)""",
}


def migrate_tablet_fleet(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='tablet_fleet_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name GLOB 'managed_tablet*' OR tbl_name GLOB 'managed_tablet*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows}
        implicit = {name: row for name, row in list(actual.items())
                    if row["type"] == "index" and row["sql"] is None}
        for name in implicit:
            actual.pop(name)
        if marker is None:
            if actual or implicit:
                raise ValueError("unmarked_tablet_fleet")
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute("INSERT INTO metadata VALUES('tablet_fleet_schema','1')")
            return
        if marker["value"] != "1" or set(actual) != set(TABLES) or any(
            row["type"] != "table" or
            " ".join(row["sql"].split()) != " ".join(TABLES[name].split())
            for name, row in actual.items()
        ):
            raise ValueError("invalid_tablet_fleet")
        expected = {"managed_tablets": 1, "managed_tablet_commands": 2,
                    "managed_tablet_events": 1,
                    "managed_tablet_audit_state": 0}
        for table, count in expected.items():
            indexes = connection.execute(f"PRAGMA index_list({table})").fetchall()
            if len(indexes) != count or any(row["origin"] not in {"pk", "u"} for row in indexes):
                raise ValueError("invalid_tablet_fleet_indexes")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("tablet_fleet_storage_invalid") from None
