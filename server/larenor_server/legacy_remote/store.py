"""Encrypted single-owner store for F56 command and audit snapshots."""

import hmac
import json
import os
import sqlite3

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from .schema import MAX_CIPHERTEXT, aad, state_tag


class LegacyRemoteStore:
    def __init__(self, database, key: bytes, context):
        self._db = database
        self._key = key
        self._cipher = AESGCM(key)
        self._core_id = context.coreId
        self._home_id = context.homeId

    def _decode(self, row):
        if (
            row is None
            or row["singleton"] != 1
            or type(row["revision"]) is not int
            or not 1 <= row["revision"] <= 2**63 - 1
            or not isinstance(row["nonce"], bytes)
            or len(row["nonce"]) != 12
            or not isinstance(row["ciphertext"], bytes)
            or not 1 <= len(row["ciphertext"]) <= MAX_CIPHERTEXT
            or not hmac.compare_digest(
                row["authentication_tag"],
                state_tag(
                    self._key,
                    self._core_id,
                    self._home_id,
                    row["revision"],
                    row["nonce"],
                    row["ciphertext"],
                ),
            )
        ):
            raise ValueError("invalid_legacy_remote_state")
        plain = self._cipher.decrypt(
            row["nonce"],
            row["ciphertext"],
            aad(self._core_id, self._home_id, row["revision"]),
        )
        if len(plain) > MAX_CIPHERTEXT:
            raise ValueError("invalid_legacy_remote_state")
        value = json.loads(plain)
        if (
            not isinstance(value, dict)
            or set(value) != {"schemaVersion", "commands", "audit"}
            or value["schemaVersion"] != 1
            or not isinstance(value["commands"], list)
            or not isinstance(value["audit"], list)
        ):
            raise ValueError("invalid_legacy_remote_state")
        return value

    def _read(self, connection):
        rows = connection.execute(
            "SELECT * FROM legacy_remote_state LIMIT 2"
        ).fetchall()
        if len(rows) != 1:
            raise ValueError("invalid_legacy_remote_state")
        return rows[0], self._decode(rows[0])

    def load(self):
        try:
            with self._db.connection() as connection:
                return self._read(connection)[1]
        except (
            InvalidTag,
            json.JSONDecodeError,
            sqlite3.Error,
            TypeError,
            ValueError,
            OverflowError,
        ):
            raise ApiError("remote_command_integrity_failed", 503) from None

    def save(self, snapshot):
        try:
            plain = json.dumps(
                snapshot,
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=True,
            ).encode("ascii")
            if not 1 <= len(plain) <= MAX_CIPHERTEXT - 32:
                raise ValueError("invalid_legacy_remote_state")
            with self._db.transaction() as connection:
                current, _ = self._read(connection)
                if current["revision"] >= 2**63 - 1:
                    raise ValueError("invalid_legacy_remote_state")
                revision = current["revision"] + 1
                nonce = os.urandom(12)
                ciphertext = self._cipher.encrypt(
                    nonce,
                    plain,
                    aad(self._core_id, self._home_id, revision),
                )
                if len(ciphertext) > MAX_CIPHERTEXT:
                    raise ValueError("invalid_legacy_remote_state")
                connection.execute(
                    "UPDATE legacy_remote_state SET revision=?,nonce=?,ciphertext=?,authentication_tag=? WHERE singleton=1",
                    (
                        revision,
                        nonce,
                        ciphertext,
                        state_tag(
                            self._key,
                            self._core_id,
                            self._home_id,
                            revision,
                            nonce,
                            ciphertext,
                        ),
                    ),
                )
        except ApiError:
            raise
        except (
            InvalidTag,
            json.JSONDecodeError,
            sqlite3.Error,
            TypeError,
            ValueError,
            OverflowError,
        ):
            raise ApiError("remote_command_integrity_failed", 503) from None

    def validate_storage(self):
        try:
            snapshot = self.load()
            if len(snapshot["commands"]) > 1_000 or len(snapshot["audit"]) > 10_000:
                raise ValueError("invalid_legacy_remote_state")
        except ApiError:
            raise StartupError("storage_initialization_failed") from None
