import sqlite3

from ..errors import StartupError


TABLES = {
    "resource_reservations": """CREATE TABLE resource_reservations (
        id TEXT PRIMARY KEY,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        resource_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 0),
        nonce BLOB NOT NULL,
        ciphertext BLOB NOT NULL,
        payload_hash TEXT NOT NULL,
        request_hash TEXT NOT NULL,
        created_at REAL NOT NULL)""",
    "resource_reservation_events": """CREATE TABLE resource_reservation_events (
        sequence INTEGER PRIMARY KEY,
        event_id TEXT NOT NULL UNIQUE,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        resource_id TEXT NOT NULL,
        command_id TEXT NOT NULL,
        action TEXT NOT NULL CHECK(action IN ('created','cancelled')),
        actor_id TEXT NOT NULL,
        reservation_id TEXT NOT NULL,
        calendar_revision INTEGER NOT NULL CHECK(calendar_revision > 0),
        occurred_at REAL NOT NULL,
        request_hash TEXT NOT NULL,
        previous_hash TEXT NOT NULL,
        event_hash TEXT NOT NULL,
        UNIQUE(core_id,home_id,resource_id,command_id),
        FOREIGN KEY(reservation_id) REFERENCES resource_reservations(id) ON DELETE RESTRICT)""",
    "resource_reservation_state": """CREATE TABLE resource_reservation_state (
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        resource_id TEXT NOT NULL,
        base_revision INTEGER NOT NULL CHECK(base_revision > 0),
        revision INTEGER NOT NULL CHECK(revision > 0),
        event_count INTEGER NOT NULL CHECK(event_count > 0),
        last_hash TEXT NOT NULL,
        state_hash TEXT NOT NULL,
        PRIMARY KEY(core_id,home_id,resource_id))""",
}

INDEXES = {
    "resource_reservation_scope": "CREATE INDEX resource_reservation_scope ON resource_reservations(core_id,home_id,resource_id,created_at,id)",
    "resource_reservation_history": "CREATE INDEX resource_reservation_history ON resource_reservation_events(core_id,home_id,resource_id,sequence)",
}


def migrate_resource_reservations(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='resource_reservation_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name GLOB 'resource_reservation*' OR tbl_name GLOB 'resource_reservation*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["sql"] is not None}
        if marker is None:
            if actual:
                raise ValueError("unmarked_resource_reservation_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            for statement in INDEXES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata VALUES('resource_reservation_schema','1')"
            )
            return
        expected = TABLES | INDEXES
        if marker["value"] != "1" or set(actual) != set(expected) or any(
            row["type"] != ("table" if name in TABLES else "index")
            or " ".join(row["sql"].split()) != " ".join(expected[name].split())
            for name, row in actual.items()
        ):
            raise ValueError("invalid_resource_reservation_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("resource_reservation_storage_invalid") from None
