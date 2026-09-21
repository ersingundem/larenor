import sqlite3

from ..errors import StartupError


TABLES = {
    "private_event_shares": """CREATE TABLE private_event_shares (
        id TEXT PRIMARY KEY,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        camera_id TEXT NOT NULL,
        event_id TEXT NOT NULL,
        nonce BLOB NOT NULL,
        ciphertext BLOB NOT NULL,
        payload_hash TEXT NOT NULL,
        token_hash TEXT NOT NULL UNIQUE,
        request_hash TEXT NOT NULL,
        created_at REAL NOT NULL)""",
    "private_event_share_events": """CREATE TABLE private_event_share_events (
        sequence INTEGER PRIMARY KEY,
        audit_id TEXT NOT NULL UNIQUE,
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        camera_id TEXT NOT NULL,
        event_id TEXT NOT NULL,
        command_id TEXT NOT NULL,
        action TEXT NOT NULL CHECK(action IN ('created','redeemed','revoked')),
        actor_id TEXT NOT NULL,
        recipient_id TEXT NOT NULL,
        share_id TEXT NOT NULL,
        share_revision INTEGER NOT NULL CHECK(share_revision > 0),
        occurred_at REAL NOT NULL,
        request_hash TEXT NOT NULL,
        previous_hash TEXT NOT NULL,
        event_hash TEXT NOT NULL,
        UNIQUE(core_id,home_id,camera_id,event_id,command_id),
        FOREIGN KEY(share_id) REFERENCES private_event_shares(id) ON DELETE RESTRICT)""",
    "private_event_share_state": """CREATE TABLE private_event_share_state (
        core_id TEXT NOT NULL,
        home_id TEXT NOT NULL,
        camera_id TEXT NOT NULL,
        event_id TEXT NOT NULL,
        base_revision INTEGER NOT NULL CHECK(base_revision > 0),
        revision INTEGER NOT NULL CHECK(revision > 0),
        event_count INTEGER NOT NULL CHECK(event_count > 0),
        last_hash TEXT NOT NULL,
        state_hash TEXT NOT NULL,
        PRIMARY KEY(core_id,home_id,camera_id,event_id))""",
}

INDEXES = {
    "private_event_share_scope": "CREATE INDEX private_event_share_scope ON private_event_shares(core_id,home_id,camera_id,event_id,created_at,id)",
    "private_event_share_history": "CREATE INDEX private_event_share_history ON private_event_share_events(core_id,home_id,camera_id,event_id,sequence)",
}


def migrate_private_event_sharing(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='private_event_share_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master WHERE "
            "name GLOB 'private_event_share*' OR tbl_name GLOB 'private_event_share*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["sql"] is not None}
        if marker is None:
            if actual:
                raise ValueError("unmarked_private_event_share_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            for statement in INDEXES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata VALUES('private_event_share_schema','1')"
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
            raise ValueError("invalid_private_event_share_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("private_event_share_storage_invalid") from None
