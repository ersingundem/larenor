"""Encrypted durable state for F56 preview/receipt idempotency."""

import hashlib
import hmac
import json
import os
import sqlite3

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.exceptions import InvalidTag

from ..errors import StartupError


SCHEMA_VERSION = "1"
MAX_CIPHERTEXT = 2 * 1024 * 1024
TABLE = """
CREATE TABLE legacy_remote_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    revision INTEGER NOT NULL CHECK(revision >= 1),
    nonce BLOB NOT NULL CHECK(length(nonce)=12),
    ciphertext BLOB NOT NULL CHECK(length(ciphertext) BETWEEN 1 AND 2097152),
    authentication_tag TEXT NOT NULL CHECK(length(authentication_tag)=64)
)
"""


def aad(core_id: str, home_id: str, revision: int) -> bytes:
    return (
        b"larenor:legacy-remote-state:v1\0"
        + json.dumps([core_id, home_id, revision], separators=(",", ":")).encode("ascii")
    )


def state_tag(key: bytes, core_id: str, home_id: str, revision: int, nonce: bytes, ciphertext: bytes) -> str:
    return hmac.new(
        key,
        b"larenor:legacy-remote-row:v1\0"
        + aad(core_id, home_id, revision)
        + nonce
        + ciphertext,
        hashlib.sha256,
    ).hexdigest()


def _empty_payload() -> bytes:
    return b'{"audit":[],"commands":[],"schemaVersion":1}'


def migrate_legacy_remote(connection: sqlite3.Connection, key: bytes, context) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='legacy_remote_schema'"
        ).fetchone()
        table = connection.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='legacy_remote_state'"
        ).fetchone()
        if marker is None:
            if table is not None:
                raise ValueError("orphaned_legacy_remote_state")
            connection.execute(TABLE)
            revision = 1
            nonce = os.urandom(12)
            ciphertext = AESGCM(key).encrypt(
                nonce,
                _empty_payload(),
                aad(context.coreId, context.homeId, revision),
            )
            connection.execute(
                "INSERT INTO legacy_remote_state VALUES(1,?,?,?,?)",
                (
                    revision,
                    nonce,
                    ciphertext,
                    state_tag(
                        key,
                        context.coreId,
                        context.homeId,
                        revision,
                        nonce,
                        ciphertext,
                    ),
                ),
            )
        elif marker["value"] != SCHEMA_VERSION or table is None:
            raise ValueError("invalid_legacy_remote_schema")
        rows = connection.execute("SELECT * FROM legacy_remote_state LIMIT 2").fetchall()
        if len(rows) != 1:
            raise ValueError("invalid_legacy_remote_state")
        row = rows[0]
        if (
            row["singleton"] != 1
            or type(row["revision"]) is not int
            or not 1 <= row["revision"] <= 2**63 - 1
            or not isinstance(row["nonce"], bytes)
            or len(row["nonce"]) != 12
            or not isinstance(row["ciphertext"], bytes)
            or not 1 <= len(row["ciphertext"]) <= MAX_CIPHERTEXT
            or not hmac.compare_digest(
                row["authentication_tag"],
                state_tag(
                    key,
                    context.coreId,
                    context.homeId,
                    row["revision"],
                    row["nonce"],
                    row["ciphertext"],
                ),
            )
        ):
            raise ValueError("invalid_legacy_remote_state")
        AESGCM(key).decrypt(
            row["nonce"],
            row["ciphertext"],
            aad(context.coreId, context.homeId, row["revision"]),
        )
        if marker is None:
            connection.execute(
                "INSERT INTO metadata VALUES('legacy_remote_schema',?)",
                (SCHEMA_VERSION,),
            )
    except (InvalidTag, sqlite3.Error, TypeError, ValueError):
        raise StartupError("storage_initialization_failed") from None
