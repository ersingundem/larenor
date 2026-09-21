import hashlib
import json
import secrets
from dataclasses import dataclass

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
MAX_DATABASE_BYTES = 512 * 1024 * 1024


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
