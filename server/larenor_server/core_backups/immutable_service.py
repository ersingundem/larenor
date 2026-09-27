import json
import secrets

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..auth import AuthService, Principal
from ..config import Settings
from ..database import Database
from ..errors import ApiError, StartupError
from .immutable_models import (
    ConfigureImmutableTargetRequest,
    ImmutableTarget,
    ImmutableTargetResponse,
)


class ImmutableBackupTargetManagement:
    """Stores separated append and recovery credentials without exposing either."""

    def __init__(
        self, db: Database, auth: AuthService, settings: Settings, key: bytes
    ):
        self.db, self.auth, self.settings = db, auth, settings
        self._cipher = AESGCM(key)

    @staticmethod
    def _aad(revision: int) -> bytes:
        return (
            f"larenor:immutable-backup-target:schema=1:revision={revision}"
        ).encode("ascii")

    def _assert_admin(self, connection, actor: Principal):
        self.auth.assert_current(connection, actor)
        if actor.must_change_password:
            raise ApiError("password_change_required", 403)
        if actor.role != "admin":
            raise ApiError("forbidden", 403)

    @staticmethod
    def _public(row) -> ImmutableTarget:
        return ImmutableTarget(
            contractVersion=1,
            revision=row["revision"],
            kind="rest_append_only_v1",
            endpoint=row["endpoint"],
            targetId=row["target_id"],
            retentionDays=row["retention_days"],
            quotaBytes=row["quota_bytes"],
            writerScope="append_only",
            recoveryScope="read_and_retain",
            configuredAt=int(row["configured_at"]),
        )

    def _secrets(self, row) -> dict:
        try:
            plain = self._cipher.decrypt(
                row["nonce"], row["ciphertext"], self._aad(row["revision"])
            )
            value = json.loads(plain)
            if (
                type(value) is not dict
                or set(value)
                != {"writeToken", "recoveryToken", "backupPassphrase"}
                or any(type(item) is not str for item in value.values())
            ):
                raise ValueError("invalid_credentials")
            ConfigureImmutableTargetRequest(
                contractVersion=1,
                expectedRevision=max(0, row["revision"] - 1),
                endpoint=row["endpoint"],
                targetId=row["target_id"],
                retentionDays=row["retention_days"],
                quotaBytes=row["quota_bytes"],
                **value,
            )
            return value
        except (InvalidTag, UnicodeError, ValueError, ValidationError):
            raise ApiError("immutable_target_unavailable", 503) from None

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                connection.execute("BEGIN")
                row = connection.execute(
                    "SELECT * FROM immutable_backup_target WHERE id=1"
                ).fetchone()
                if row is not None:
                    self._secrets(row)
        except ApiError:
            raise StartupError("invalid_immutable_backup_target_storage") from None

    def get(self, actor: Principal) -> ImmutableTargetResponse:
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            row = connection.execute(
                "SELECT * FROM immutable_backup_target WHERE id=1"
            ).fetchone()
            if row is not None:
                self._secrets(row)
        return ImmutableTargetResponse(
            target=None if row is None else self._public(row)
        )

    def configure(
        self, actor: Principal, body: ConfigureImmutableTargetRequest
    ) -> ImmutableTargetResponse:
        with self.db.transaction() as connection:
            self._assert_admin(connection, actor)
            row = connection.execute(
                "SELECT * FROM immutable_backup_target WHERE id=1"
            ).fetchone()
            revision = 0 if row is None else row["revision"]
            if revision != body.expectedRevision:
                raise ApiError("revision_conflict", 409)
            revision += 1
            credentials = {
                "writeToken": body.writeToken,
                "recoveryToken": body.recoveryToken,
                "backupPassphrase": body.backupPassphrase,
            }
            nonce = secrets.token_bytes(12)
            ciphertext = self._cipher.encrypt(
                nonce,
                json.dumps(credentials, separators=(",", ":")).encode("utf-8"),
                self._aad(revision),
            )
            configured_at = int(self.settings.clock())
            connection.execute(
                "INSERT INTO immutable_backup_target VALUES(1,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,"
                "endpoint=excluded.endpoint,target_id=excluded.target_id,"
                "retention_days=excluded.retention_days,"
                "quota_bytes=excluded.quota_bytes,nonce=excluded.nonce,"
                "ciphertext=excluded.ciphertext,configured_at=excluded.configured_at",
                (
                    revision,
                    body.endpoint,
                    body.targetId,
                    body.retentionDays,
                    body.quotaBytes,
                    nonce,
                    ciphertext,
                    configured_at,
                ),
            )
            result = connection.execute(
                "SELECT * FROM immutable_backup_target WHERE id=1"
            ).fetchone()
        return ImmutableTargetResponse(target=self._public(result))

