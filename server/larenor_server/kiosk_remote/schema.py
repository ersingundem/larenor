import sqlite3

from ..errors import StartupError


TABLES = {
    "kiosk_remote_pairings": """CREATE TABLE kiosk_remote_pairings (
        id TEXT PRIMARY KEY, request_id TEXT NOT NULL UNIQUE,
        request_hash TEXT NOT NULL,
        device_id TEXT NOT NULL, owner_id TEXT NOT NULL, family_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 0),
        name TEXT NOT NULL, scopes TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
        token_nonce BLOB NOT NULL, token_ciphertext BLOB NOT NULL,
        expires_at REAL NOT NULL, active INTEGER NOT NULL CHECK(active IN (0,1)),
        created_at REAL NOT NULL, updated_at REAL NOT NULL, record_tag TEXT NOT NULL,
        FOREIGN KEY(device_id) REFERENCES managed_tablets(id) ON DELETE CASCADE)""",
    "kiosk_remote_commands": """CREATE TABLE kiosk_remote_commands (
        id TEXT PRIMARY KEY, pairing_id TEXT NOT NULL, request_id TEXT NOT NULL,
        sequence INTEGER NOT NULL CHECK(sequence > 0), kind TEXT NOT NULL,
        expires_at REAL NOT NULL, state TEXT NOT NULL CHECK(state IN ('accepted','completed')),
        result TEXT, request_hash TEXT NOT NULL, created_at REAL NOT NULL,
        completed_at REAL, record_tag TEXT NOT NULL,
        UNIQUE(pairing_id,request_id), UNIQUE(pairing_id,sequence),
        FOREIGN KEY(pairing_id) REFERENCES kiosk_remote_pairings(id) ON DELETE CASCADE)""",
}


def migrate_kiosk_remote(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='kiosk_remote_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,sql FROM sqlite_master WHERE name GLOB 'kiosk_remote*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["type"] == "table"}
        if marker is None:
            if actual:
                raise ValueError("unmarked_kiosk_remote")
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata VALUES('kiosk_remote_schema','1')"
            )
            return
        if marker["value"] != "1" or set(actual) != set(TABLES) or any(
            " ".join(actual[name]["sql"].split()) != " ".join(sql.split())
            for name, sql in TABLES.items()
        ):
            raise ValueError("invalid_kiosk_remote")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("kiosk_remote_storage_invalid") from None
