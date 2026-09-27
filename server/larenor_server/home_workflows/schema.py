"""Additive storage for durable home workflows."""

from ..errors import StartupError


TABLE = "home_workflows"
MAX_WORKFLOWS = 256
MAX_CIPHERTEXT = 32768
_COLUMNS = (
    ("id", "TEXT", 0, None, 1),
    ("sequence", "INTEGER", 1, None, 0),
    ("revision", "INTEGER", 1, None, 0),
    ("actor_id", "TEXT", 1, None, 0),
    ("request_id", "TEXT", 1, None, 0),
    ("state", "TEXT", 1, None, 0),
    ("attempt", "INTEGER", 1, None, 0),
    ("step_request_id", "TEXT", 0, None, 0),
    ("effect_state", "TEXT", 1, None, 0),
    ("reconciliation_result", "TEXT", 1, None, 0),
    ("cancel_requested", "INTEGER", 1, None, 0),
    ("deadline_at", "REAL", 1, None, 0),
    ("created_at", "REAL", 1, None, 0),
    ("updated_at", "REAL", 1, None, 0),
    ("nonce", "BLOB", 1, None, 0),
    ("ciphertext", "BLOB", 1, None, 0),
)


def _verify(connection):
    columns = tuple(tuple(row) for row in connection.execute(
        f'SELECT name,type,"notnull",dflt_value,pk FROM pragma_table_info(\'{TABLE}\')'
    ))
    if columns != _COLUMNS:
        raise StartupError("home_workflows_schema_unsupported")
    unique = set()
    for index in connection.execute(f"PRAGMA index_list({TABLE})"):
        fields = tuple(row[0] for row in connection.execute(
            "SELECT name FROM pragma_index_info(?) ORDER BY seqno", (index["name"],)
        ))
        if index["unique"] and not index["partial"]:
            unique.add(fields)
    if unique != {
        ("id",), ("sequence",), ("actor_id", "request_id"), ("step_request_id",),
    }:
        raise StartupError("home_workflows_schema_unsupported")


def migrate_home_workflows(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='home_workflows_schema'"
    ).fetchone()
    tables = {row[0] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='home_workflows'"
    )}
    if marker is None:
        if tables:
            raise StartupError("home_workflows_schema_unsupported")
        connection.execute(f"""CREATE TABLE {TABLE} (
            id TEXT PRIMARY KEY,
            sequence INTEGER NOT NULL UNIQUE CHECK(sequence > 0),
            revision INTEGER NOT NULL CHECK(revision > 0),
            actor_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN (
                'waiting_decision','running','reconciliation_required','completed',
                'failed','cancelled','timed_out')),
            attempt INTEGER NOT NULL CHECK(attempt BETWEEN 1 AND 3),
            step_request_id TEXT UNIQUE,
            effect_state TEXT NOT NULL CHECK(effect_state IN (
                'not_started','accepted','rejected','unknown')),
            reconciliation_result TEXT NOT NULL CHECK(reconciliation_result IN (
                'none','effect_applied','effect_not_applied')),
            cancel_requested INTEGER NOT NULL CHECK(cancel_requested IN (0,1)),
            deadline_at REAL NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            nonce BLOB NOT NULL,
            ciphertext BLOB NOT NULL,
            UNIQUE(actor_id, request_id)
        )""")
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES('home_workflows_schema','1')"
        )
    elif marker["value"] != "1" or tables != {TABLE}:
        raise StartupError("home_workflows_schema_unsupported")
    _verify(connection)
