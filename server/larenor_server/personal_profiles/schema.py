"""Additive account-scoped Core remote profile persistence schema."""
import sqlite3

from ..errors import StartupError

MAX_PROFILES_PER_ACCOUNT = 32
MAX_AUDIT = 10000
MAX_RECEIPTS_PER_ACCOUNT = 256
MAX_RECEIPTS = 10000
TABLES = {
    'personal_profile_records': '''CREATE TABLE personal_profile_records (
        owner_id TEXT NOT NULL REFERENCES users(id), id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 0),
        nonce BLOB NOT NULL, ciphertext BLOB NOT NULL,
        PRIMARY KEY(owner_id,id))''',
    'personal_profile_state': '''CREATE TABLE personal_profile_state (
        owner_id TEXT PRIMARY KEY REFERENCES users(id),
        revision INTEGER NOT NULL CHECK(revision >= 0),
        record_count INTEGER NOT NULL CHECK(record_count >= 0),
        authentication_tag TEXT NOT NULL)''',
    'personal_profile_audit': '''CREATE TABLE personal_profile_audit (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        action TEXT NOT NULL CHECK(action IN ('create','update','delete')),
        status TEXT NOT NULL CHECK(status IN ('success','denied')),
        actor_id TEXT NOT NULL, family_id TEXT NOT NULL,
        request_id TEXT NOT NULL, target_id TEXT NOT NULL,
        created_at REAL NOT NULL, authentication_tag TEXT NOT NULL)''',
    'personal_profile_audit_state': '''CREATE TABLE personal_profile_audit_state (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        revision INTEGER NOT NULL CHECK(revision >= 0),
        record_count INTEGER NOT NULL CHECK(record_count >= 0),
        rows_digest TEXT NOT NULL, authentication_tag TEXT NOT NULL)''',
    'personal_profile_receipts': '''CREATE TABLE personal_profile_receipts (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        owner_id TEXT NOT NULL REFERENCES users(id), family_id TEXT NOT NULL,
        request_id TEXT NOT NULL, action TEXT NOT NULL
            CHECK(action IN ('create','update','delete')),
        request_hash TEXT NOT NULL, nonce BLOB NOT NULL, ciphertext BLOB NOT NULL,
        created_at REAL NOT NULL,
        UNIQUE(owner_id,family_id,request_id))''',
}


def migrate_personal_profiles(connection):
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='personal_profiles_schema'"
        ).fetchone()
        existing = {
            row['name']: row for row in connection.execute(
                "SELECT name,type,sql FROM sqlite_master WHERE type='table' "
                "AND name GLOB 'personal_profile_*'"
            )
        }
        if marker is None:
            if existing:
                raise ValueError()
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata VALUES('personal_profiles_schema','2')"
            )
        elif marker['value'] != '2' or set(existing) != set(TABLES) or any(
                row['type'] != 'table' or
                ' '.join(row['sql'].split()) != ' '.join(TABLES[name].split())
                for name, row in existing.items()):
            raise ValueError()
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError('personal_profile_storage_invalid') from None
