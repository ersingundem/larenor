import sqlite3

from ..errors import StartupError

TABLES = {
    "shared_expense_records": """CREATE TABLE shared_expense_records (
        id TEXT PRIMARY KEY,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 0),
        nonce BLOB NOT NULL,
        ciphertext BLOB NOT NULL,
        payload_hash TEXT NOT NULL,
        created_at REAL NOT NULL)""",
    "shared_expense_events": """CREATE TABLE shared_expense_events (
        sequence INTEGER PRIMARY KEY,
        event_id TEXT NOT NULL UNIQUE,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        command_id TEXT NOT NULL,
        action TEXT NOT NULL CHECK(action='created'),
        actor_id TEXT NOT NULL,
        record_id TEXT NOT NULL,
        ledger_revision INTEGER NOT NULL CHECK(ledger_revision > 1),
        occurred_at REAL NOT NULL,
        request_hash TEXT NOT NULL,
        previous_hash TEXT NOT NULL,
        event_hash TEXT NOT NULL,
        UNIQUE(core_id,home_id,command_id),
        FOREIGN KEY(record_id) REFERENCES shared_expense_records(id) ON DELETE RESTRICT)""",
    "shared_expense_state": """CREATE TABLE shared_expense_state (
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 1),
        event_count INTEGER NOT NULL CHECK(event_count > 0),
        last_hash TEXT NOT NULL,
        state_hash TEXT NOT NULL,
        PRIMARY KEY(core_id,home_id))""",
}
INDEXES = {
    "shared_expense_scope": "CREATE INDEX shared_expense_scope ON shared_expense_records(core_id,home_id,created_at,id)",
    "shared_expense_history": "CREATE INDEX shared_expense_history ON shared_expense_events(core_id,home_id,sequence)",
}


def migrate_shared_expenses(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='shared_expense_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name GLOB 'shared_expense_*' OR tbl_name GLOB 'shared_expense_*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["sql"] is not None}
        if marker is None:
            if actual:
                raise ValueError("unmarked_shared_expense_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            for statement in INDEXES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata VALUES('shared_expense_schema','1')"
            )
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
            raise ValueError("invalid_shared_expense_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("shared_expense_storage_invalid") from None
