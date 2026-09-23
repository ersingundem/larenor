"""Encrypted account-to-managed-Jellyfin identity bindings."""

import sqlite3

from ..errors import StartupError


MAX_BINDINGS = 256
DDL = """CREATE TABLE media_account_bindings (
    account_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    installation_id TEXT NOT NULL REFERENCES media_installations(id),
    revision INTEGER NOT NULL CHECK(revision > 0),
    bootstrap_revision INTEGER NOT NULL CHECK(bootstrap_revision > 0),
    nonce BLOB NOT NULL,
    ciphertext BLOB NOT NULL,
    PRIMARY KEY(account_id,installation_id))"""


def migrate_media_account_bindings(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='media_account_bindings_schema'"
        ).fetchone()
        existing = connection.execute(
            "SELECT type,sql FROM sqlite_master WHERE name='media_account_bindings'"
        ).fetchone()
        if marker is None:
            if existing is not None:
                raise ValueError()
            connection.execute(DDL)
            connection.execute(
                "INSERT INTO metadata VALUES('media_account_bindings_schema','1')"
            )
        elif (
            marker["value"] != "1"
            or existing is None
            or existing["type"] != "table"
            or " ".join(existing["sql"].split()) != " ".join(DDL.split())
        ):
            raise ValueError()
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("media_account_binding_storage_invalid") from None
