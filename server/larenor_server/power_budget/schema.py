import sqlite3

from ..errors import StartupError


TABLES = {
    "power_budget_previews": """CREATE TABLE power_budget_previews (
        id TEXT PRIMARY KEY,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        meter_id TEXT NOT NULL,
        account_id TEXT NOT NULL,
        plan_revision INTEGER NOT NULL CHECK(plan_revision > 0),
        plan_hash TEXT NOT NULL,
        request_hash TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at REAL NOT NULL,
        record_hash TEXT NOT NULL)""",
    "power_budget_commands": """CREATE TABLE power_budget_commands (
        command_id TEXT PRIMARY KEY,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        meter_id TEXT NOT NULL,
        account_id TEXT NOT NULL,
        preview_id TEXT NOT NULL,
        plan_hash TEXT NOT NULL,
        request_hash TEXT NOT NULL,
        created_at REAL NOT NULL,
        record_hash TEXT NOT NULL,
        FOREIGN KEY(preview_id) REFERENCES power_budget_previews(id) ON DELETE RESTRICT)""",
    "power_budget_events": """CREATE TABLE power_budget_events (
        sequence INTEGER PRIMARY KEY,
        audit_id TEXT NOT NULL UNIQUE,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        meter_id TEXT NOT NULL,
        action TEXT NOT NULL CHECK(action IN ('previewed','dispatch_reserved','confirm_uncertain','awaiting_readback','readback_mismatch','verified')),
        actor_id TEXT NOT NULL,
        object_id TEXT NOT NULL,
        plan_hash TEXT NOT NULL,
        occurred_at REAL NOT NULL,
        request_hash TEXT NOT NULL,
        previous_hash TEXT NOT NULL,
        event_hash TEXT NOT NULL)""",
    "power_budget_audit_state": """CREATE TABLE power_budget_audit_state (
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        meter_id TEXT NOT NULL,
        event_count INTEGER NOT NULL CHECK(event_count > 0),
        last_hash TEXT NOT NULL,
        state_hash TEXT NOT NULL,
        PRIMARY KEY(core_id,home_id,meter_id))""",
}

INDEXES = {
    "power_budget_preview_scope": "CREATE INDEX power_budget_preview_scope ON power_budget_previews(core_id,home_id,meter_id,created_at,id)",
    "power_budget_command_scope": "CREATE INDEX power_budget_command_scope ON power_budget_commands(core_id,home_id,meter_id,created_at,command_id)",
    "power_budget_history_scope": "CREATE INDEX power_budget_history_scope ON power_budget_events(core_id,home_id,meter_id,sequence)",
}


def migrate_power_budget(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='power_budget_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name GLOB 'power_budget_*' OR tbl_name GLOB 'power_budget_*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["sql"] is not None}
        if marker is None:
            if actual:
                raise ValueError("unmarked_power_budget_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            for statement in INDEXES.values():
                connection.execute(statement)
            connection.execute("INSERT INTO metadata VALUES('power_budget_schema','1')")
            return
        expected = TABLES | INDEXES
        if marker["value"] != "1" or set(actual) != set(expected) or any(
            row["type"] != ("table" if name in TABLES else "index")
            or " ".join(row["sql"].split()) != " ".join(expected[name].split())
            for name, row in actual.items()
        ):
            raise ValueError("invalid_power_budget_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("power_budget_storage_invalid") from None
