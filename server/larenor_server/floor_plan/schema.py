import sqlite3

from ..errors import StartupError


TABLES = {
    "floor_plan_layouts": """CREATE TABLE floor_plan_layouts (
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        account_id TEXT NOT NULL,
        core_revision INTEGER NOT NULL CHECK(core_revision > 0),
        home_revision INTEGER NOT NULL CHECK(home_revision > 0),
        revision INTEGER NOT NULL CHECK(revision > 0),
        entity_registry_revision INTEGER NOT NULL CHECK(entity_registry_revision > 0),
        resource_revision INTEGER NOT NULL CHECK(resource_revision > 0),
        payload TEXT NOT NULL,
        updated_at REAL NOT NULL,
        record_hash TEXT NOT NULL,
        PRIMARY KEY(core_id,home_id))""",
    "floor_plan_requests": """CREATE TABLE floor_plan_requests (
        request_id TEXT PRIMARY KEY,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        account_id TEXT NOT NULL,
        session_id TEXT NOT NULL,
        request_hash TEXT NOT NULL,
        result_revision INTEGER NOT NULL CHECK(result_revision > 0),
        created_at REAL NOT NULL,
        record_hash TEXT NOT NULL)""",
    "floor_plan_events": """CREATE TABLE floor_plan_events (
        sequence INTEGER PRIMARY KEY,
        audit_id TEXT NOT NULL UNIQUE,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        action TEXT NOT NULL CHECK(action='layout_replaced'),
        actor_id TEXT NOT NULL,
        object_id TEXT NOT NULL,
        layout_revision INTEGER NOT NULL CHECK(layout_revision > 0),
        occurred_at REAL NOT NULL,
        request_hash TEXT NOT NULL,
        previous_hash TEXT NOT NULL,
        event_hash TEXT NOT NULL)""",
    "floor_plan_audit_state": """CREATE TABLE floor_plan_audit_state (
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        event_count INTEGER NOT NULL CHECK(event_count > 0),
        last_hash TEXT NOT NULL,
        state_hash TEXT NOT NULL,
        PRIMARY KEY(core_id,home_id))""",
}

INDEXES = {
    "floor_plan_request_scope": "CREATE INDEX floor_plan_request_scope ON floor_plan_requests(core_id,home_id,created_at,request_id)",
    "floor_plan_history_scope": "CREATE INDEX floor_plan_history_scope ON floor_plan_events(core_id,home_id,sequence)",
}


def migrate_floor_plan(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='floor_plan_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name GLOB 'floor_plan_*' OR tbl_name GLOB 'floor_plan_*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["sql"] is not None}
        if marker is None:
            if actual:
                raise ValueError("unmarked_floor_plan_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            for statement in INDEXES.values():
                connection.execute(statement)
            connection.execute("INSERT INTO metadata VALUES('floor_plan_schema','1')")
            return
        expected = TABLES | INDEXES
        if marker["value"] != "1" or set(actual) != set(expected) or any(
            row["type"] != ("table" if name in TABLES else "index")
            or " ".join(row["sql"].split()) != " ".join(expected[name].split())
            for name, row in actual.items()
        ):
            raise ValueError("invalid_floor_plan_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("floor_plan_storage_invalid") from None
