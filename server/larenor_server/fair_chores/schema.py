import sqlite3

from ..errors import StartupError


TABLES = {
    "fair_chore_tasks": """CREATE TABLE fair_chore_tasks (
        id TEXT PRIMARY KEY,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        title TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 0),
        assignee_id TEXT NOT NULL,
        members_revision INTEGER NOT NULL CHECK(members_revision > 0),
        member_order_json TEXT NOT NULL,
        timezone_name TEXT NOT NULL,
        interval_days INTEGER NOT NULL CHECK(interval_days BETWEEN 1 AND 365),
        due_at REAL NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL)""",
    "fair_chore_events": """CREATE TABLE fair_chore_events (
        sequence INTEGER PRIMARY KEY,
        event_id TEXT NOT NULL UNIQUE,
        task_id TEXT NOT NULL,
        command_id TEXT NOT NULL,
        action TEXT NOT NULL CHECK(action IN ('created','completed','deferred')),
        actor_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 0),
        occurred_at REAL NOT NULL,
        receipt_json TEXT NOT NULL,
        previous_hash TEXT NOT NULL,
        event_hash TEXT NOT NULL,
        UNIQUE(task_id,command_id),
        FOREIGN KEY(task_id) REFERENCES fair_chore_tasks(id) ON DELETE RESTRICT)""",
}
INDEXES = {
    "fair_chore_scope": "CREATE INDEX fair_chore_scope ON fair_chore_tasks(core_id,home_id,due_at,id)",
    "fair_chore_history": "CREATE INDEX fair_chore_history ON fair_chore_events(task_id,sequence)",
}


def migrate_fair_chores(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='fair_chore_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name GLOB 'fair_chore_*' OR tbl_name GLOB 'fair_chore_*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["sql"] is not None}
        if marker is None:
            if actual:
                raise ValueError("unmarked_fair_chore_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            for statement in INDEXES.values():
                connection.execute(statement)
            connection.execute("INSERT INTO metadata VALUES('fair_chore_schema','1')")
            return
        expected = TABLES | INDEXES
        if marker["value"] != "1" or set(actual) != set(expected) or any(
            row["type"] != ("table" if name in TABLES else "index")
            or " ".join(row["sql"].split()) != " ".join(expected[name].split())
            for name, row in actual.items()
        ):
            raise ValueError("invalid_fair_chore_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("fair_chore_storage_invalid") from None
