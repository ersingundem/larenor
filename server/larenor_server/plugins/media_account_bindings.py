"""Durable private identity authority for account-specific media history."""

from dataclasses import dataclass
import re
import secrets
import sqlite3

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ConfigDict, Field

from ..errors import ApiError, StartupError
from ..models import StrictModel
from .media_account_binding_schema import MAX_BINDINGS


class _StoredBinding(StrictModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)
    jellyfinUserId: str = Field(pattern=r"^[0-9a-f]{32}$", repr=False)


@dataclass(frozen=True, repr=False)
class MediaAccountBindingPrivate:
    account_id: str
    installation_id: str
    installation_revision: int
    binding_revision: int
    bootstrap_revision: int
    jellyfin_user_id: str

    def __repr__(self):
        return "MediaAccountBindingPrivate(<private>)"


class MediaAccountBindingManagement:
    """Only trusted Core code can create or resolve an upstream identity."""

    def __init__(self, db, auth, key, bootstraps):
        self.db, self.auth = db, auth
        self._cipher = AESGCM(key)
        self.bootstraps = bootstraps

    @staticmethod
    def _identity(value):
        if type(value) is not str or re.fullmatch(r"[0-9a-f]{32}", value) is None:
            raise ValueError()

    @staticmethod
    def _aad(row):
        return (
            "larenor-media-account-binding-v1:"
            f"{row['account_id']}:{row['installation_id']}:"
            f"{row['revision']}:{row['bootstrap_revision']}"
        ).encode("ascii")

    def _decode(self, row):
        self._identity(row["account_id"])
        self._identity(row["installation_id"])
        if (
            type(row["revision"]) is not int
            or not 1 <= row["revision"] <= 2**63 - 1
            or type(row["bootstrap_revision"]) is not int
            or not 1 <= row["bootstrap_revision"] <= 2**63 - 1
            or type(row["nonce"]) is not bytes
            or len(row["nonce"]) != 12
            or type(row["ciphertext"]) is not bytes
            or not 16 <= len(row["ciphertext"]) <= 256
        ):
            raise ValueError()
        return _StoredBinding.model_validate_json(
            self._cipher.decrypt(row["nonce"], row["ciphertext"], self._aad(row))
        )

    def bind_verified_bootstrap(self, connection, bootstrap, private):
        readback = private.readback
        if (
            readback is None
            or bootstrap["state"] not in {"wiring_partial", "succeeded"}
            or bootstrap["credentials_configured"] != 1
        ):
            raise ValueError("unverified_bootstrap")
        account_id = bootstrap["actor_id"]
        installation_id = bootstrap["installation_id"]
        current = connection.execute(
            "SELECT * FROM media_account_bindings "
            "WHERE account_id=? AND installation_id=?",
            (account_id, installation_id),
        ).fetchone()
        if current is None:
            if connection.execute(
                "SELECT COUNT(*) FROM media_account_bindings"
            ).fetchone()[0] >= MAX_BINDINGS:
                raise ValueError("binding_limit")
            revision = 1
        else:
            previous = self._decode(current)
            revision = current["revision"]
            if previous.jellyfinUserId != readback.userId:
                if revision >= 2**63 - 1:
                    raise ValueError("revision_overflow")
                revision += 1
        row = {
            "account_id": account_id,
            "installation_id": installation_id,
            "revision": revision,
            "bootstrap_revision": bootstrap["revision"],
        }
        plain = _StoredBinding(
            jellyfinUserId=readback.userId
        ).model_dump_json().encode("utf-8")
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(nonce, plain, self._aad(row))
        connection.execute(
            "INSERT INTO media_account_bindings VALUES(?,?,?,?,?,?) "
            "ON CONFLICT(account_id,installation_id) DO UPDATE SET "
            "revision=excluded.revision,"
            "bootstrap_revision=excluded.bootstrap_revision,"
            "nonce=excluded.nonce,ciphertext=excluded.ciphertext",
            (
                account_id,
                installation_id,
                revision,
                bootstrap["revision"],
                nonce,
                ciphertext,
            ),
        )

    def resolve(self, actor, installation_id, installation_revision):
        self._identity(installation_id)
        if (
            type(installation_revision) is not int
            or not 1 <= installation_revision <= 2**63 - 1
        ):
            raise ApiError("media_account_binding_changed", 409)
        try:
            with self.db.connection() as connection:
                connection.execute("BEGIN")
                self.auth.assert_current(connection, actor)
                account = connection.execute(
                    "SELECT revision,disabled,must_change_password FROM users WHERE id=?",
                    (actor.id,),
                ).fetchone()
                row = connection.execute(
                    "SELECT * FROM media_account_bindings "
                    "WHERE account_id=? AND installation_id=?",
                    (actor.id, installation_id),
                ).fetchone()
                installation = connection.execute(
                    "SELECT revision,state,phase,cancel_requested,error_code "
                    "FROM media_installations WHERE id=?",
                    (installation_id,),
                ).fetchone()
                bootstrap = connection.execute(
                    "SELECT * FROM media_service_bootstraps "
                    "WHERE installation_id=?",
                    (installation_id,),
                ).fetchone()
                if (
                    account is None
                    or account["disabled"]
                    or account["must_change_password"]
                    or row is None
                    or installation is None
                    or installation["revision"] != installation_revision
                    or installation["state"] != "container_started"
                    or installation["phase"] != "complete"
                    or installation["cancel_requested"]
                    or installation["error_code"] is not None
                    or bootstrap is None
                    or bootstrap["actor_id"] != actor.id
                    or bootstrap["revision"] != row["bootstrap_revision"]
                    or bootstrap["state"] not in {"wiring_partial", "succeeded"}
                    or bootstrap["credentials_configured"] != 1
                ):
                    raise ApiError("media_account_binding_changed", 409)
                value = self._decode(row)
                bootstrap_private = self.bootstraps._validate_row(
                    connection, bootstrap
                )
                if (
                    bootstrap_private.readback is None
                    or bootstrap_private.readback.userId != value.jellyfinUserId
                ):
                    raise ApiError("media_account_binding_changed", 409)
                return MediaAccountBindingPrivate(
                    account_id=actor.id,
                    installation_id=installation_id,
                    installation_revision=installation_revision,
                    binding_revision=row["revision"],
                    bootstrap_revision=row["bootstrap_revision"],
                    jellyfin_user_id=value.jellyfinUserId,
                )
        except ApiError:
            raise
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("media_account_binding_unavailable", 503) from None

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM media_account_bindings LIMIT ?",
                    (MAX_BINDINGS + 1,),
                ).fetchall()
                if len(rows) > MAX_BINDINGS:
                    raise ValueError()
                for row in rows:
                    self._decode(row)
                    bootstrap = connection.execute(
                        "SELECT * "
                        "FROM media_service_bootstraps WHERE installation_id=?",
                        (row["installation_id"],),
                    ).fetchone()
                    if (
                        bootstrap is None
                        or bootstrap["revision"] != row["bootstrap_revision"]
                        or bootstrap["state"] not in {"wiring_partial", "succeeded"}
                        or bootstrap["credentials_configured"] != 1
                    ):
                        raise ValueError()
                    private = self.bootstraps._validate_row(connection, bootstrap)
                    if (
                        private.readback is None
                        or private.readback.userId
                        != self._decode(row).jellyfinUserId
                    ):
                        raise ValueError()
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise StartupError("media_account_binding_storage_invalid") from None
