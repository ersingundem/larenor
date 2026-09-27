import hashlib
import json
import os
import secrets
import threading
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..auth import AuthService, Principal
from ..config import Settings
from ..database import Database
from ..errors import ApiError, StartupError
from ..files import private_create, private_directory, private_read, sync_directory
from .drill_service import RecoveryDrillAuthority
from .immutable_models import (
    ConfigureImmutableTargetRequest,
    ImmutableTarget,
    ImmutableTargetResponse,
    ImmutableRestorePoint,
    ImmutableRestorePointsResponse,
)
from .immutable_transport import RestAppendOnlyTransport


DAY_SECONDS = 24 * 60 * 60
MAX_PENDING_BYTES = 512 * 1024 * 1024


class ImmutableBackupTargetManagement:
    """Stores separated append and recovery credentials without exposing either."""

    def __init__(
        self,
        db: Database,
        auth: AuthService,
        settings: Settings,
        key: bytes,
        backup_contract,
        transport=None,
    ):
        self.db, self.auth, self.settings = db, auth, settings
        self._cipher = AESGCM(key)
        self._backup = backup_contract
        self.transport = transport or RestAppendOnlyTransport()
        self._lock = threading.Lock()
        self._pending = settings.data_dir / "immutable-backup-pending"
        private_directory(self._pending)

    @staticmethod
    def _aad(revision: int) -> bytes:
        return (
            f"larenor:immutable-backup-target:schema=1:revision={revision}"
        ).encode("ascii")

    def _assert_admin(self, connection, actor: Principal):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT revision,role,disabled,must_change_password FROM users "
            "WHERE id=?",
            (actor.id,),
        ).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("forbidden", 403)
        if row["role"] != "admin":
            raise ApiError("forbidden", 403)
        return row["revision"]

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
            nextRunAt=row["next_run_at"],
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
                    if (
                        (row["actor_id"] is None)
                        != (row["actor_revision"] is None)
                        or (row["actor_id"] is None) != (row["family_id"] is None)
                        or (row["actor_id"] is None) != (row["next_run_at"] is None)
                    ):
                        raise ApiError("immutable_target_unavailable", 503)
                jobs = connection.execute(
                    "SELECT * FROM immutable_backup_job"
                ).fetchall()
                if len(jobs) > 1:
                    raise ApiError("immutable_target_unavailable", 503)
                if jobs:
                    path = self._path(jobs[0]["object_id"])
                    if jobs[0]["state"] == "prepared":
                        payload = private_read(path, MAX_PENDING_BYTES)
                        if (
                            len(payload) != jobs[0]["byte_length"]
                            or hashlib.sha256(payload).hexdigest()
                            != jobs[0]["sha256"]
                        ):
                            raise ApiError("immutable_target_unavailable", 503)
                    elif path.exists():
                        raise ApiError("immutable_target_unavailable", 503)
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

    @staticmethod
    def _point(row) -> ImmutableRestorePoint:
        return ImmutableRestorePoint(
            objectId=row["object_id"],
            targetRevision=row["target_revision"],
            createdAt=row["created_at"],
            protectedUntil=row["protected_until"],
            byteLength=row["byte_length"],
            sha256=row["sha256"],
            remoteReceiptId=row["remote_receipt_id"],
        )

    def points(self, actor: Principal) -> ImmutableRestorePointsResponse:
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            target = connection.execute(
                "SELECT * FROM immutable_backup_target WHERE id=1"
            ).fetchone()
            if target is None:
                raise ApiError("immutable_target_not_configured", 409)
            rows = connection.execute(
                "SELECT * FROM immutable_backup_points "
                "ORDER BY sequence DESC LIMIT 100"
            ).fetchall()
        return ImmutableRestorePointsResponse(
            points=[self._point(row) for row in rows],
            quotaUsedBytes=0 if not rows else rows[0]["quota_used_bytes"],
            quotaBytes=target["quota_bytes"],
        )

    def configure(
        self, actor: Principal, body: ConfigureImmutableTargetRequest
    ) -> ImmutableTargetResponse:
        with self.db.transaction() as connection:
            actor_revision = self._assert_admin(connection, actor)
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
            next_run_at = configured_at + DAY_SECONDS
            connection.execute(
                "INSERT INTO immutable_backup_target("
                "id,revision,endpoint,target_id,retention_days,quota_bytes,nonce,"
                "ciphertext,configured_at,actor_id,actor_revision,family_id,next_run_at) "
                "VALUES(1,?,?,?,?,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,"
                "endpoint=excluded.endpoint,target_id=excluded.target_id,"
                "retention_days=excluded.retention_days,"
                "quota_bytes=excluded.quota_bytes,nonce=excluded.nonce,"
                "ciphertext=excluded.ciphertext,configured_at=excluded.configured_at,"
                "actor_id=excluded.actor_id,actor_revision=excluded.actor_revision,"
                "family_id=excluded.family_id,next_run_at=excluded.next_run_at",
                (
                    revision,
                    body.endpoint,
                    body.targetId,
                    body.retentionDays,
                    body.quotaBytes,
                    nonce,
                    ciphertext,
                    configured_at,
                    actor.id,
                    actor_revision,
                    actor.family_id,
                    next_run_at,
                ),
            )
            result = connection.execute(
                "SELECT * FROM immutable_backup_target WHERE id=1"
            ).fetchone()
        return ImmutableTargetResponse(target=self._public(result))

    def _path(self, object_id):
        if (
            type(object_id) is not str
            or len(object_id) != 32
            or any(char not in "0123456789abcdef" for char in object_id)
        ):
            raise ApiError("immutable_target_unavailable", 503)
        return self._pending / object_id

    @staticmethod
    def _authority(row):
        return RecoveryDrillAuthority(
            actor_id=row["actor_id"],
            actor_revision=row["actor_revision"],
            family_id=row["family_id"],
            scheduled=True,
        )

    def _job(self):
        with self.db.transaction() as connection:
            row = connection.execute(
                "SELECT * FROM immutable_backup_job WHERE id=1"
            ).fetchone()
            if row is not None:
                target = connection.execute(
                    "SELECT * FROM immutable_backup_target WHERE id=1"
                ).fetchone()
                return row, target
            target = connection.execute(
                "SELECT * FROM immutable_backup_target WHERE id=1"
            ).fetchone()
            now = int(self.settings.clock())
            if (
                target is None
                or target["next_run_at"] is None
                or target["next_run_at"] > now
            ):
                return None, target
            object_id = uuid.uuid4().hex
            protected_until = now + target["retention_days"] * DAY_SECONDS
            connection.execute(
                "INSERT INTO immutable_backup_job VALUES(1,?,?,?,'queued',?,NULL,NULL)",
                (object_id, target["revision"], target["next_run_at"], protected_until),
            )
            return connection.execute(
                "SELECT * FROM immutable_backup_job WHERE id=1"
            ).fetchone(), target

    def _prepare(self, job, target, credentials):
        publication = self._backup.publish_for_authority(
            self._authority(target), credentials["backupPassphrase"]
        )
        payload = publication.payload
        digest = hashlib.sha256(payload).hexdigest()
        path, temporary = self._path(job["object_id"]), self._pending / (
            ".prepare-" + uuid.uuid4().hex
        )
        try:
            private_create(temporary, payload)
            os.replace(temporary, path)
            sync_directory(self._pending)
        finally:
            if temporary.exists():
                temporary.unlink()
        with self.db.transaction() as connection:
            current = connection.execute(
                "SELECT * FROM immutable_backup_job WHERE id=1"
            ).fetchone()
            if (
                current is None
                or current["object_id"] != job["object_id"]
                or current["state"] != "queued"
            ):
                path.unlink(missing_ok=True)
                raise ApiError("immutable_target_unavailable", 503)
            connection.execute(
                "UPDATE immutable_backup_job SET state='prepared',"
                "byte_length=?,sha256=? WHERE id=1",
                (len(payload), digest),
            )
            return connection.execute(
                "SELECT * FROM immutable_backup_job WHERE id=1"
            ).fetchone()

    def tick(self):
        if not self._lock.acquire(blocking=False):
            return False
        try:
            job, target = self._job()
            if job is None:
                return False
            if target is None or target["revision"] != job["target_revision"]:
                raise ApiError("immutable_target_changed", 409)
            credentials = self._secrets(target)
            if job["state"] == "queued":
                job = self._prepare(job, target, credentials)
            payload = private_read(self._path(job["object_id"]), MAX_PENDING_BYTES)
            receipt = self.transport.append(
                endpoint=target["endpoint"],
                target_id=target["target_id"],
                object_id=job["object_id"],
                payload=payload,
                sha256=job["sha256"],
                protected_until=job["protected_until"],
                write_token=credentials["writeToken"],
            )
            with self.db.transaction() as connection:
                current = connection.execute(
                    "SELECT * FROM immutable_backup_job WHERE id=1"
                ).fetchone()
                if current is None or current["object_id"] != job["object_id"]:
                    raise ApiError("immutable_target_unavailable", 503)
                sequence = connection.execute(
                    "SELECT COALESCE(MAX(sequence),0)+1 FROM immutable_backup_points"
                ).fetchone()[0]
                connection.execute(
                    "INSERT INTO immutable_backup_points VALUES(?,?,?,?,?,?,?,?,?)",
                    (
                        job["object_id"],
                        sequence,
                        job["target_revision"],
                        receipt.storedAt,
                        receipt.protectedUntil,
                        receipt.byteLength,
                        receipt.sha256,
                        receipt.remoteReceiptId,
                        receipt.quotaUsedBytes,
                    ),
                )
                connection.execute("DELETE FROM immutable_backup_job WHERE id=1")
                connection.execute(
                    "UPDATE immutable_backup_target SET next_run_at=? WHERE id=1",
                    (max(int(self.settings.clock()), job["due_at"]) + DAY_SECONDS,),
                )
            self._path(job["object_id"]).unlink()
            sync_directory(self._pending)
            return True
        finally:
            self._lock.release()
