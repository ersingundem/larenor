import sqlite3

from ..errors import StartupError


TABLES = {
    "private_event_share_policy": """CREATE TABLE private_event_share_policy (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        revision INTEGER NOT NULL CHECK(revision > 0),
        nonce BLOB NOT NULL,
        ciphertext BLOB NOT NULL,
        record_hash TEXT NOT NULL,
        updated_at REAL NOT NULL,
        updated_by TEXT NOT NULL)""",
    "private_event_share_bindings": """CREATE TABLE private_event_share_bindings (
        camera_id TEXT NOT NULL,
        event_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 0),
        nonce BLOB NOT NULL,
        ciphertext BLOB NOT NULL,
        record_hash TEXT NOT NULL,
        expires_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY(camera_id,event_id))""",
    "private_event_share_consents": """CREATE TABLE private_event_share_consents (
        id TEXT PRIMARY KEY,
        revision INTEGER NOT NULL CHECK(revision > 0),
        issuer_id TEXT NOT NULL,
        recipient_id TEXT NOT NULL,
        camera_id TEXT NOT NULL,
        event_id TEXT NOT NULL,
        nonce BLOB NOT NULL,
        ciphertext BLOB NOT NULL,
        record_hash TEXT NOT NULL,
        expires_at REAL NOT NULL,
        created_at REAL NOT NULL)""",
    "private_event_share_artifacts": """CREATE TABLE private_event_share_artifacts (
        id TEXT PRIMARY KEY,
        nonce BLOB NOT NULL,
        ciphertext BLOB NOT NULL,
        digest TEXT NOT NULL,
        byte_length INTEGER NOT NULL CHECK(byte_length > 0),
        record_hash TEXT NOT NULL,
        expires_at REAL NOT NULL,
        created_at REAL NOT NULL)""",
}

INDEXES = {
    "private_event_share_binding_expiry": "CREATE INDEX private_event_share_binding_expiry ON private_event_share_bindings(expires_at)",
    "private_event_share_consent_scope": "CREATE INDEX private_event_share_consent_scope ON private_event_share_consents(camera_id,event_id,issuer_id,expires_at)",
    "private_event_share_artifact_expiry": "CREATE INDEX private_event_share_artifact_expiry ON private_event_share_artifacts(expires_at)",
}

FOUNDATION_OBJECTS = {
    "private_event_shares",
    "private_event_share_events",
    "private_event_share_state",
    "private_event_share_scope",
    "private_event_share_history",
}


def migrate_private_event_share_provider(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='private_event_share_provider_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,sql FROM sqlite_master WHERE "
            "name GLOB 'private_event_share*' OR tbl_name GLOB 'private_event_share*'"
        ).fetchall()
        discovered = {row["name"]: row for row in rows if row["sql"] is not None}
        expected = TABLES | INDEXES
        if set(discovered) - set(expected) - FOUNDATION_OBJECTS:
            raise ValueError("unknown_private_event_share_provider_storage")
        actual = {
            name: row for name, row in discovered.items() if name in expected
        }
        if marker is None:
            if actual:
                raise ValueError("unmarked_private_event_share_provider_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            for statement in INDEXES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata VALUES('private_event_share_provider_schema','1')"
            )
            return
        if (
            marker["value"] != "1"
            or set(actual) != set(expected)
            or any(
                row["type"] != ("table" if name in TABLES else "index")
                or " ".join(row["sql"].split())
                != " ".join(expected[name].split())
                for name, row in actual.items()
            )
        ):
            raise ValueError("invalid_private_event_share_provider_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("private_event_share_provider_storage_invalid") from None
