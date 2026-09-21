import sqlite3

from ..errors import StartupError


MAX_SUBSCRIPTIONS = 256
MAX_EVENTS = 10000
MAX_DELIVERIES = 50000

TABLES = {
    "local_notification_subscriptions": """CREATE TABLE local_notification_subscriptions (
        id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, family_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 0),
        permission TEXT NOT NULL CHECK(permission IN ('granted','denied')),
        state TEXT NOT NULL CHECK(state IN ('active','revoked')),
        expires_at REAL NOT NULL, created_at REAL NOT NULL,
        envelope_tag TEXT NOT NULL)""",
    "local_notification_events": """CREATE TABLE local_notification_events (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL UNIQUE, recipient_id TEXT NOT NULL,
        idempotency_key TEXT NOT NULL, envelope_tag TEXT NOT NULL,
        nonce BLOB NOT NULL, ciphertext BLOB NOT NULL, created_at REAL NOT NULL,
        UNIQUE(recipient_id,idempotency_key))""",
    "local_notification_acks": """CREATE TABLE local_notification_acks (
        subscription_id TEXT NOT NULL, sequence INTEGER NOT NULL,
        delivered_at REAL NOT NULL, acknowledged_at REAL,
        PRIMARY KEY(subscription_id,sequence),
        FOREIGN KEY(subscription_id) REFERENCES local_notification_subscriptions(id) ON DELETE CASCADE,
        FOREIGN KEY(sequence) REFERENCES local_notification_events(sequence) ON DELETE CASCADE)""",
}


def migrate_local_notifications(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='local_notification_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name GLOB 'local_notification_*' OR tbl_name GLOB 'local_notification_*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows}
        implicit = {
            name: row for name, row in list(actual.items())
            if row["type"] == "index" and row["sql"] is None
        }
        for name in implicit:
            actual.pop(name)
        if marker is None:
            if actual or implicit:
                raise ValueError("unmarked_local_notification_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute("INSERT INTO metadata VALUES('local_notification_schema','1')")
            return
        if marker["value"] != "1" or set(actual) != set(TABLES) or any(
            row["type"] != "table"
            or " ".join(row["sql"].split()) != " ".join(TABLES[name].split())
            for name, row in actual.items()
        ):
            raise ValueError("invalid_local_notification_storage")
        expected_indexes = {
            "local_notification_subscriptions": 1,
            "local_notification_events": 2,
            "local_notification_acks": 1,
        }
        for table, count in expected_indexes.items():
            indexes = connection.execute(f"PRAGMA index_list({table})").fetchall()
            if len(indexes) != count or any(row["origin"] not in {"pk", "u"} for row in indexes):
                raise ValueError("invalid_local_notification_indexes")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("local_notification_storage_invalid") from None
