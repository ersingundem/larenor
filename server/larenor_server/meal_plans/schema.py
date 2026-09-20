import sqlite3

from ..errors import StartupError


MAX_RECORDS = 256
MAX_RECEIPTS = 10000
MAX_RECEIPTS_PER_ACCOUNT = 256
TABLES = {
    'meal_plan_records': '''CREATE TABLE meal_plan_records (
        owner_id TEXT PRIMARY KEY REFERENCES users(id),
        revision INTEGER NOT NULL CHECK(revision > 0),
        nonce BLOB NOT NULL, ciphertext BLOB NOT NULL)''',
    'meal_plan_receipts': '''CREATE TABLE meal_plan_receipts (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        owner_id TEXT NOT NULL REFERENCES users(id), family_id TEXT NOT NULL,
        request_id TEXT NOT NULL, request_hash TEXT NOT NULL,
        nonce BLOB NOT NULL, ciphertext BLOB NOT NULL,
        UNIQUE(owner_id,family_id,request_id))''',
}


def migrate_meal_plans(connection):
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='meal_plans_schema'"
        ).fetchone()
        existing = {
            row['name']: row for row in connection.execute(
                "SELECT name,type,sql FROM sqlite_master WHERE type='table' "
                "AND name GLOB 'meal_plan_*'"
            )
        }
        if marker is None:
            if existing:
                raise ValueError()
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata VALUES('meal_plans_schema','1')"
            )
        elif marker['value'] != '1' or set(existing) != set(TABLES) or any(
            row['type'] != 'table' or
            ' '.join(row['sql'].split()) != ' '.join(TABLES[name].split())
            for name, row in existing.items()
        ):
            raise ValueError()
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError('meal_plan_storage_invalid') from None
