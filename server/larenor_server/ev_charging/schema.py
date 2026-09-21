import sqlite3

from ..errors import StartupError

TABLES = {
    "ev_charge_previews": """CREATE TABLE ev_charge_previews (
        id TEXT PRIMARY KEY,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        charger_id TEXT NOT NULL,
        account_id TEXT NOT NULL,
        schedule_revision INTEGER NOT NULL CHECK(schedule_revision > 0),
        plan_hash TEXT NOT NULL,
        request_hash TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at REAL NOT NULL,
        record_hash TEXT NOT NULL)""",
    "ev_charge_commands": """CREATE TABLE ev_charge_commands (
        command_id TEXT PRIMARY KEY,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        charger_id TEXT NOT NULL,
        account_id TEXT NOT NULL,
        preview_id TEXT NOT NULL,
        plan_hash TEXT NOT NULL,
        request_hash TEXT NOT NULL,
        created_at REAL NOT NULL,
        record_hash TEXT NOT NULL,
        FOREIGN KEY(preview_id) REFERENCES ev_charge_previews(id) ON DELETE RESTRICT)""",
    "ev_charge_events": """CREATE TABLE ev_charge_events (
        sequence INTEGER PRIMARY KEY,
        audit_id TEXT NOT NULL UNIQUE,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        charger_id TEXT NOT NULL,
        action TEXT NOT NULL CHECK(action IN ('previewed','dispatch_reserved','confirm_uncertain','awaiting_readback','readback_mismatch','verified')),
        actor_id TEXT NOT NULL,
        object_id TEXT NOT NULL,
        plan_hash TEXT NOT NULL,
        occurred_at REAL NOT NULL,
        request_hash TEXT NOT NULL,
        previous_hash TEXT NOT NULL,
        event_hash TEXT NOT NULL)""",
    "ev_charge_audit_state": """CREATE TABLE ev_charge_audit_state (
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        charger_id TEXT NOT NULL,
        event_count INTEGER NOT NULL CHECK(event_count > 0),
        last_hash TEXT NOT NULL,
        state_hash TEXT NOT NULL,
        PRIMARY KEY(core_id,home_id,charger_id))""",
}

INDEXES = {
    "ev_charge_preview_scope": "CREATE INDEX ev_charge_preview_scope ON ev_charge_previews(core_id,home_id,charger_id,created_at,id)",
    "ev_charge_command_scope": "CREATE INDEX ev_charge_command_scope ON ev_charge_commands(core_id,home_id,charger_id,created_at,command_id)",
    "ev_charge_history_scope": "CREATE INDEX ev_charge_history_scope ON ev_charge_events(core_id,home_id,charger_id,sequence)",
}


def migrate_ev_charging(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='ev_charge_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name GLOB 'ev_charge_*' OR tbl_name GLOB 'ev_charge_*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["sql"] is not None}
        if marker is None:
            if actual:
                raise ValueError("unmarked_ev_charge_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            for statement in INDEXES.values():
                connection.execute(statement)
            connection.execute("INSERT INTO metadata VALUES('ev_charge_schema','1')")
            return
        expected = TABLES | INDEXES
        if (
            marker["value"] != "1"
            or set(actual) != set(expected)
            or any(
                row["type"] != ("table" if name in TABLES else "index")
                or " ".join(row["sql"].split()) != " ".join(expected[name].split())
                for name, row in actual.items()
            )
        ):
            raise ValueError("invalid_ev_charge_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("ev_charge_storage_invalid") from None
