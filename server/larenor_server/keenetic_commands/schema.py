import sqlite3

from ..errors import StartupError


ZERO = "0" * 64
MAX_COMMANDS = 1024
MAX_EVENTS = MAX_COMMANDS * 3

TABLES = {
    "keenetic_command_records": """CREATE TABLE keenetic_command_records (
        request_id TEXT PRIMARY KEY, actor_id TEXT NOT NULL,
        idempotency_hash TEXT NOT NULL, resource_id TEXT NOT NULL,
        action TEXT NOT NULL, status TEXT NOT NULL,
        target_json TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
        UNIQUE(actor_id,idempotency_hash))""",
    "keenetic_command_events": """CREATE TABLE keenetic_command_events (
        sequence INTEGER PRIMARY KEY CHECK(sequence>0), request_id TEXT NOT NULL,
        actor_id TEXT NOT NULL, resource_id TEXT NOT NULL, status TEXT NOT NULL,
        payload_json TEXT NOT NULL, previous_hash TEXT NOT NULL,
        entry_hash TEXT NOT NULL, created_at REAL NOT NULL)""",
    "keenetic_command_chain_state": """CREATE TABLE keenetic_command_chain_state (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1), chain_id TEXT NOT NULL,
        sequence INTEGER NOT NULL CHECK(sequence>=0), head_hash TEXT NOT NULL,
        authentication_tag TEXT NOT NULL)""",
}


def migrate(connection, key, scope, state_tag):
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='keenetic_command_schema'"
        ).fetchone()
        names = set(TABLES)
        found = {
            row["name"]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name GLOB 'keenetic_command_*'"
            )
        }
        if marker is None:
            if found:
                raise ValueError("partial_schema")
            import secrets

            for sql in TABLES.values():
                connection.execute(sql)
            chain_id = secrets.token_hex(16)
            connection.execute(
                "INSERT INTO keenetic_command_chain_state VALUES(1,?,0,?,?)",
                (chain_id, ZERO, state_tag(scope, chain_id, 0, ZERO)),
            )
            connection.execute(
                "INSERT INTO metadata VALUES('keenetic_command_schema','1')"
            )
        elif marker["value"] != "1" or found != names:
            raise ValueError("invalid_schema")
    except (sqlite3.Error, ValueError, TypeError):
        raise StartupError("keenetic_command_storage_invalid") from None
