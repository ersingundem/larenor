import hashlib
import io
import json
import secrets
import threading
import zipfile
from dataclasses import dataclass

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
from pydantic import ValidationError

from ..auth import AuthService, Principal
from ..config import Settings
from ..database import Database
from ..errors import ApiError
from ..files import private_read
from ..legal import server_version
from .models import BackupManifest, BackupResource

_ACTIVE = (
    ("bounded_transfer_receipts", "state='accepted'", "active_bounded_transfer"),
    ("plugin_jobs", "state IN ('queued','running')", "active_plugin_job"),
    ("media_inspections", "state IN ('queued','running')", "active_media_inspection"),
    (
        "media_installations",
        "state IN ('queued','running','container_started')",
        "active_media_installation",
    ),
    (
        "media_service_bootstraps",
        "state IN ('queued','running','credentials_configured','wiring_partial')",
        "active_media_bootstrap",
    ),
    (
        "media_qbittorrent_configurations",
        "state IN ('queued','running')",
        "active_qbittorrent_configuration",
    ),
    (
        "media_arr_configurations",
        "state IN ('queued','running')",
        "active_arr_configuration",
    ),
    (
        "media_seerr_bootstraps",
        "state IN ('queued','running')",
        "active_seerr_bootstrap",
    ),
    (
        "media_music_assistant_bootstraps",
        "state IN ('queued','running')",
        "active_music_assistant_bootstrap",
    ),
    (
        "keenetic_command_records",
        "status IN ('accepted','executing')",
        "active_keenetic_command",
    ),
    (
        "managed_tablet_commands",
        "state IN ('pending','delivered')",
        "active_tablet_command",
    ),
)
MAX_DATABASE_BYTES = 128 * 1024 * 1024
MAGIC = b"LARENOR-CORE-BACKUP\x00\x01"
MAX_BUNDLE_BYTES = MAX_DATABASE_BYTES + 8 * 1024 * 1024
_MANIFEST_NAME = "manifest.json"


def _canonical(value) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("ascii")


def _resource(identifier, kind, version, payload):
    return BackupResource(
        id=identifier,
        kind=kind,
        version=version,
        byteLength=len(payload),
        sha256=hashlib.sha256(payload).hexdigest(),
    )


@dataclass(frozen=True)
class BackupCapture:
    """Private bytes and their public manifest; never returned by the API."""

    manifest: BackupManifest
    payloads: dict[str, bytes]


class BackupBlocked(Exception):
    def __init__(self, blockers):
        self.blockers = blockers


class CoreBackupContract:
    """Creates a redacted, consistent manifest without exporting secret bytes."""

    def __init__(self, db: Database, auth: AuthService, settings: Settings):
        self.db, self.auth, self.settings = db, auth, settings
        self._export_lock = threading.Lock()

    @staticmethod
    def _blockers(connection):
        tables = {
            row["name"]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            )
        }
        return [
            code
            for table, predicate, code in _ACTIVE
            if table in tables
            and connection.execute(
                f"SELECT 1 FROM {table} WHERE {predicate} LIMIT 1"
            ).fetchone()
        ]

    @staticmethod
    def _schema_versions(connection):
        values = {}
        for row in connection.execute(
            "SELECT key,value FROM metadata WHERE key LIKE '%_schema' ORDER BY key"
        ):
            try:
                version = int(row["value"])
            except (TypeError, ValueError):
                continue
            if version > 0:
                values[row["key"]] = version
        return values

    def capture(self, actor: Principal) -> BackupCapture:
        with self.db.connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            self.auth.assert_current(connection, actor)
            blockers = self._blockers(connection)
            if blockers:
                connection.rollback()
                raise BackupBlocked(blockers)
            schema = int(
                connection.execute(
                    "SELECT value FROM metadata WHERE key='schema_version'"
                ).fetchone()["value"]
            )
            component_versions = self._schema_versions(connection)
            page_bytes = connection.execute("PRAGMA page_size").fetchone()[0]
            page_count = connection.execute("PRAGMA page_count").fetchone()[0]
            if page_bytes * page_count > MAX_DATABASE_BYTES:
                connection.rollback()
                raise ApiError("backup_too_large", 413)
            database = connection.serialize()
            connection.rollback()

        key = private_read(self.settings.key_file, 32)
        configuration = _canonical(
            {
                "contractVersion": 1,
                "workers": {
                    "installation": self.settings.installation_worker_socket
                    is not None,
                    "keenetic": self.settings.keenetic_worker_socket is not None,
                    "plugin": self.settings.plugin_worker_socket is not None,
                    "proxmox": self.settings.proxmox_power_worker_socket is not None,
                },
            }
        )
        component_index = _canonical(
            {
                "contractVersion": 1,
                "schemas": component_versions,
            }
        )
        payloads = {
            "core-database": database,
            "vault-key": key,
            "core-configuration": configuration,
            "component-index": component_index,
        }
        resources = sorted(
            (
                _resource("core-database", "database", str(schema), database),
                _resource("vault-key", "vaultKey", "aes256-v1", key),
                _resource("core-configuration", "configuration", "1", configuration),
                _resource("component-index", "componentData", "1", component_index),
            ),
            key=lambda item: item.id,
        )
        manifest = BackupManifest(
            contractVersion=1,
            snapshotId=secrets.token_hex(16),
            createdAt=int(self.settings.clock()),
            coreVersion=server_version(),
            databaseSchemaVersion=schema,
            componentSchemaVersions=component_versions,
            resources=resources,
        )
        return BackupCapture(manifest=manifest, payloads=payloads)

    def plan(self, actor: Principal):
        try:
            capture = self.capture(actor)
        except BackupBlocked as error:
            return {"status": "blocked", "blockers": error.blockers, "manifest": None}
        return {"status": "ready", "blockers": [], "manifest": capture.manifest}

    def validate_restore(self, manifest: BackupManifest):
        reasons = []
        if manifest.contractVersion != 1:
            reasons.append("unsupported_contract_version")
        with self.db.connection() as connection:
            current_schema = int(
                connection.execute(
                    "SELECT value FROM metadata WHERE key='schema_version'"
                ).fetchone()["value"]
            )
            component_versions = self._schema_versions(connection)
        if manifest.databaseSchemaVersion != current_schema:
            reasons.append("database_schema_mismatch")
        if manifest.coreVersion != server_version():
            reasons.append("core_version_mismatch")
        if manifest.componentSchemaVersions != component_versions:
            reasons.append("component_schema_mismatch")
        return {"compatible": not reasons, "reasons": reasons}

    @staticmethod
    def _derive_key(passphrase: str, salt: bytes) -> bytes:
        return Scrypt(salt=salt, length=32, n=2**15, r=8, p=1).derive(
            passphrase.encode("utf-8")
        )

    @staticmethod
    def _archive(capture: BackupCapture) -> bytes:
        output = io.BytesIO()
        with zipfile.ZipFile(
            output, mode="w", compression=zipfile.ZIP_DEFLATED, compresslevel=6
        ) as archive:
            archive.writestr(
                _MANIFEST_NAME,
                capture.manifest.model_dump_json(by_alias=True, exclude_none=True),
            )
            for identifier in sorted(capture.payloads):
                archive.writestr(
                    f"resources/{identifier}", capture.payloads[identifier]
                )
        value = output.getvalue()
        if len(value) > MAX_BUNDLE_BYTES:
            raise ApiError("backup_too_large", 413)
        return value

    def export(self, actor: Principal, passphrase: str) -> bytes:
        if not self._export_lock.acquire(blocking=False):
            raise ApiError("backup_busy", 409)
        try:
            try:
                capture = self.capture(actor)
            except BackupBlocked:
                raise ApiError("backup_blocked", 409) from None
            salt, nonce = secrets.token_bytes(16), secrets.token_bytes(12)
            aad = MAGIC + salt + nonce
            return aad + AESGCM(self._derive_key(passphrase, salt)).encrypt(
                nonce, self._archive(capture), aad
            )
        finally:
            self._export_lock.release()

    def open_bundle(self, bundle: bytes, passphrase: str) -> BackupCapture:
        try:
            header = len(MAGIC) + 16 + 12
            if (
                type(bundle) is not bytes
                or not header + 16 <= len(bundle) <= MAX_BUNDLE_BYTES
                or bundle[: len(MAGIC)] != MAGIC
            ):
                raise ValueError("invalid_bundle")
            salt = bundle[len(MAGIC) : len(MAGIC) + 16]
            nonce = bundle[len(MAGIC) + 16 : header]
            aad = bundle[:header]
            plaintext = AESGCM(self._derive_key(passphrase, salt)).decrypt(
                nonce, bundle[header:], aad
            )
            with zipfile.ZipFile(io.BytesIO(plaintext), mode="r") as archive:
                infos = archive.infolist()
                names = [item.filename for item in infos]
                if (
                    len(infos) != 5
                    or len(set(names)) != len(names)
                    or _MANIFEST_NAME not in names
                    or any(
                        item.is_dir() or item.file_size > MAX_BUNDLE_BYTES
                        for item in infos
                    )
                    or sum(item.file_size for item in infos) > MAX_BUNDLE_BYTES
                ):
                    raise ValueError("invalid_archive")
                manifest_bytes = archive.read(_MANIFEST_NAME)
                if len(manifest_bytes) > 256 * 1024:
                    raise ValueError("invalid_manifest")
                manifest = BackupManifest.model_validate_json(manifest_bytes)
                expected = {f"resources/{item.id}" for item in manifest.resources}
                if set(names) != expected | {_MANIFEST_NAME}:
                    raise ValueError("invalid_resources")
                payloads = {
                    item.id: archive.read(f"resources/{item.id}")
                    for item in manifest.resources
                }
            for resource in manifest.resources:
                payload = payloads[resource.id]
                if len(payload) != resource.byteLength or not secrets.compare_digest(
                    hashlib.sha256(payload).hexdigest(), resource.sha256
                ):
                    raise ValueError("invalid_digest")
            return BackupCapture(manifest=manifest, payloads=payloads)
        except (
            InvalidTag,
            OSError,
            UnicodeError,
            ValueError,
            ValidationError,
            zipfile.BadZipFile,
            RuntimeError,
        ):
            raise ApiError("backup_decryption_failed") from None
