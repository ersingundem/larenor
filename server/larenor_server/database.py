from contextlib import contextmanager
import sqlite3
from pathlib import Path
from collections.abc import Iterator


ADMIN_SCHEMA = """
CREATE TABLE IF NOT EXISTS admin_audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event TEXT NOT NULL,
    action TEXT NOT NULL,
    object TEXT NOT NULL CHECK(object IN ('user','session')),
    status TEXT NOT NULL CHECK(status IN ('success','denied')),
    timestamp REAL NOT NULL,
    actor_id TEXT NOT NULL,
    target_id TEXT
);
"""

SCHEMA = """
CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    role TEXT NOT NULL CHECK(role IN ('admin','member')),
    password_hash TEXT NOT NULL,
    must_change_password INTEGER NOT NULL CHECK(must_change_password IN (0,1)),
    created_at REAL NOT NULL,
    disabled INTEGER NOT NULL DEFAULT 0 CHECK(disabled IN (0,1)),
    revision INTEGER NOT NULL DEFAULT 1 CHECK(revision > 0)
);
CREATE TABLE IF NOT EXISTS session_families (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    device_name TEXT NOT NULL,
    created_at REAL NOT NULL,
    expires_at REAL NOT NULL,
    revoked_at REAL
);
CREATE INDEX IF NOT EXISTS families_user ON session_families(user_id);
CREATE TABLE IF NOT EXISTS session_tokens (
    id TEXT PRIMARY KEY,
    family_id TEXT NOT NULL REFERENCES session_families(id),
    access_hash TEXT NOT NULL UNIQUE,
    refresh_hash TEXT NOT NULL UNIQUE,
    access_expires_at REAL NOT NULL,
    refresh_expires_at REAL NOT NULL,
    created_at REAL NOT NULL,
    rotated_at REAL
);
CREATE INDEX IF NOT EXISTS tokens_family ON session_tokens(family_id);
CREATE TABLE IF NOT EXISTS vaults (
    user_id TEXT PRIMARY KEY REFERENCES users(id),
    revision INTEGER NOT NULL CHECK(revision > 0),
    nonce BLOB NOT NULL,
    ciphertext BLOB NOT NULL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS rate_limits (
    key TEXT PRIMARY KEY,
    window INTEGER NOT NULL,
    count INTEGER NOT NULL,
    touched_at REAL NOT NULL
);
""" + ADMIN_SCHEMA


class Database:
    def __init__(self, path: Path):
        self.path = path

    @contextmanager
    def connection(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.row_factory = sqlite3.Row
        try:
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("PRAGMA busy_timeout=5000")
            connection.execute("PRAGMA synchronous=FULL")
            yield connection
        finally:
            connection.close()

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        with self.connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                yield connection
                connection.commit()
            except BaseException:
                connection.rollback()
                raise

    def create_schema(self) -> None:
        with self.connection() as connection:
            if connection.execute("PRAGMA journal_mode=WAL").fetchone()[0] != "wal":
                raise sqlite3.OperationalError("WAL unavailable")
            # executescript's transaction is explicit, including first initialization.
            connection.executescript("BEGIN IMMEDIATE;\n" + SCHEMA + "\nCOMMIT;")

    @staticmethod
    def migrate_v1(connection: sqlite3.Connection) -> None:
        # Caller verified the vault key and holds the initialization write lock.
        # DDL and schema marker commit together; no resets or credential changes.
        connection.execute("ALTER TABLE users ADD COLUMN disabled INTEGER NOT NULL DEFAULT 0 CHECK(disabled IN (0,1))")
        connection.execute("ALTER TABLE users ADD COLUMN revision INTEGER NOT NULL DEFAULT 1 CHECK(revision > 0)")
        connection.execute(ADMIN_SCHEMA)
        connection.execute("UPDATE metadata SET value='2' WHERE key='schema_version'")
