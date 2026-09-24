import hashlib
import hmac
import io
import json
import re
import secrets
import sqlite3
import threading
import time
import zipfile
from contextlib import closing, contextmanager
from dataclasses import dataclass, field

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
from pydantic import ValidationError

from ..auth import AuthService, Principal
from ..config import Settings
from ..database import Database
from ..errors import ApiError, StartupError
from ..files import checked_path, private_read
from ..legal import server_version
from ..plugins.catalog import load_catalog
from .models import (
    MAX_COMPONENT_BYTES,
    MAX_COMPONENT_VOLUME_BYTES,
    MAX_DATABASE_BYTES,
    MAX_FAMILY_BOARD_BYTES,
    BackupConsistencyBoundary,
    BackupManifest,
    BackupResource,
    ComponentBackup,
)

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
        "music_assistant_key_rotations",
        "state IN ('preparing','activated')",
        "active_music_key_rotation",
    ),
    (
        "proxmox_power_journal",
        (
            "state IN ('accepted','executing') AND sequence=("
            "SELECT MAX(latest.sequence) FROM proxmox_power_journal AS latest "
            "WHERE latest.request_id=proxmox_power_journal.request_id)"
        ),
        "active_proxmox_command",
    ),
    (
        "keenetic_command_records",
        "status IN ('accepted','executing')",
        "active_keenetic_command",
    ),
    (
        "managed_tablet_commands",
        "state IN ('pending','delivered') AND expires_at>:now",
        "active_tablet_command",
    ),
    (
        "kiosk_remote_commands",
        "state='accepted' AND expires_at>:now",
        "active_kiosk_command",
    ),
    (
        "game_stream_commands",
        (
            "state='authorized' AND EXISTS("
            "SELECT 1 FROM game_stream_sessions AS session "
            "WHERE session.id=game_stream_commands.session_id "
            "AND session.state='open' AND session.expires_at>:now)"
        ),
        "active_game_stream_command",
    ),
)
COMPONENT_QUIESCENCE_SECONDS = 5
MAGIC = b"LARENOR-CORE-BACKUP\x00\x01"
BUNDLE_ENVELOPE_BYTES = len(MAGIC) + 16 + 12 + 16
MAX_BUNDLE_BYTES = (
    MAX_DATABASE_BYTES
    + MAX_FAMILY_BOARD_BYTES
    + MAX_COMPONENT_BYTES
    + 8 * 1024 * 1024
)
_MANIFEST_NAME = "manifest.json"
_DATABASE_VALIDATION_VM_STEP_INTERVAL = 1_000
_DATABASE_VALIDATION_VM_STEP_BUDGET = 100_000
_SCHEMA_MARKER_KEY = re.compile(r"^[A-Za-z0-9_]{1,64}$")
_SCHEMA_MARKER_VALUE = re.compile(r"^[1-9][0-9]{0,9}$")
_CAPTURE_GENERATION = re.compile(r"^[0-9a-f]{32}$")
_BUNDLE_AUTHENTICATION = object()


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


def _open_authenticated_bundle(bundle: bytes, passphrase: str) -> "BackupCapture":
    """Authenticate and decode one bounded bundle without semantic acceptance."""
    try:
        header = len(MAGIC) + 16 + 12
        if (
            type(bundle) is not bytes
            or not BUNDLE_ENVELOPE_BYTES <= len(bundle) <= MAX_BUNDLE_BYTES
            or bundle[: len(MAGIC)] != MAGIC
        ):
            raise ValueError("invalid_bundle")
        salt = bundle[len(MAGIC) : len(MAGIC) + 16]
        nonce = bundle[len(MAGIC) + 16 : header]
        aad = bundle[:header]
        key = Scrypt(salt=salt, length=32, n=2**15, r=8, p=1).derive(
            passphrase.encode("utf-8")
        )
        plaintext = AESGCM(key).decrypt(nonce, bundle[header:], aad)
        with zipfile.ZipFile(io.BytesIO(plaintext), mode="r") as archive:
            infos = archive.infolist()
            names = [item.filename for item in infos]
            if (
                not 5 <= len(infos) <= 134
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
        return BackupCapture(
            manifest=manifest,
            payloads=payloads,
            _bundle_authentication=_BUNDLE_AUTHENTICATION,
        )
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


def open_backup_bundle(bundle: bytes, passphrase: str) -> "BackupCapture":
    """Open one bundle and hide every decode or semantic failure alike."""
    capture = _open_authenticated_bundle(bundle, passphrase)
    try:
        _validate_payload_contract(capture)
    except ValueError:
        raise ApiError("backup_decryption_failed") from None
    return capture


@dataclass(frozen=True)
class BackupCapture:
    """Private bytes and their public manifest; never returned by the API."""

    manifest: BackupManifest
    payloads: dict[str, bytes]
    _bundle_authentication: object = field(default=None, compare=False, repr=False)


def _is_authenticated_backup_capture(capture: BackupCapture) -> bool:
    """Prove this exact capture came from successful bundle authentication."""

    return (
        type(capture) is BackupCapture
        and capture._bundle_authentication is _BUNDLE_AUTHENTICATION
    )


def _validate_payload_contract(capture: BackupCapture) -> None:
    """Bind authenticated metadata payloads to the public manifest exactly."""
    try:
        configuration_bytes = capture.payloads["core-configuration"]
        component_index_bytes = capture.payloads["component-index"]
        database_bytes = capture.payloads["core-database"]
        configuration = json.loads(configuration_bytes)
        component_index = json.loads(component_index_bytes)
        if (
            type(database_bytes) is not bytes
            or not 20 <= len(database_bytes) <= MAX_DATABASE_BYTES
            or database_bytes[:16] != b"SQLite format 3\x00"
        ):
            raise ValueError("invalid_database")
        database_image = bytearray(database_bytes)
        # Serialized WAL databases need a rollback-journal header before an
        # isolated in-memory reader can inspect them without a sidecar file.
        database_image[18:20] = b"\x01\x01"
        with closing(sqlite3.connect(":memory:")) as database:
            database.row_factory = sqlite3.Row
            database.deserialize(database_image)
            database.execute("PRAGMA trusted_schema=OFF")
            database.execute("PRAGMA query_only=ON")
            executed_steps = 0

            def interrupt_expensive_validation():
                nonlocal executed_steps
                executed_steps += _DATABASE_VALIDATION_VM_STEP_INTERVAL
                return executed_steps > _DATABASE_VALIDATION_VM_STEP_BUDGET

            database.set_progress_handler(
                interrupt_expensive_validation,
                _DATABASE_VALIDATION_VM_STEP_INTERVAL,
            )
            metadata_object = database.execute(
                """
                SELECT type, tbl_name
                FROM sqlite_schema
                WHERE name = 'metadata' COLLATE BINARY
                """
            ).fetchall()
            metadata_columns = [
                tuple(row)
                for row in database.execute("PRAGMA table_xinfo('metadata')")
            ]
            if (
                [tuple(row) for row in metadata_object]
                != [("table", "metadata")]
                or metadata_columns
                != [
                    (0, "key", "TEXT", 0, None, 1, 0),
                    (1, "value", "TEXT", 1, None, 0, 0),
                ]
            ):
                raise ValueError("invalid_metadata_table")
            schema_row = database.execute(
                "SELECT value FROM metadata WHERE key='schema_version'"
            ).fetchone()
            database_schema = int(schema_row["value"])
            component_schemas = CoreBackupContract._schema_versions(database)
        expected_components = [
            component.model_dump(mode="json")
            for component in capture.manifest.components
        ]
        expected_index = {
            "contractVersion": (
                2 if capture.manifest.consistencyBoundary is not None else 1
            ),
            "schemas": capture.manifest.componentSchemaVersions,
        }
        if expected_index["contractVersion"] == 2:
            expected_index["components"] = expected_components
        if (
            type(configuration) is not dict
            or set(configuration) != {"contractVersion", "workers"}
            or configuration["contractVersion"] != 1
            or type(configuration["workers"]) is not dict
            or set(configuration["workers"])
            != {"installation", "keenetic", "plugin", "proxmox"}
            or any(
                type(value) is not bool
                for value in configuration["workers"].values()
            )
            or configuration_bytes != _canonical(configuration)
            or database_schema != capture.manifest.databaseSchemaVersion
            or component_schemas != capture.manifest.componentSchemaVersions
            or component_index != expected_index
            or component_index_bytes != _canonical(component_index)
        ):
            raise ValueError("invalid_backup_payload_contract")
    except (
        KeyError,
        OverflowError,
        sqlite3.Error,
        TypeError,
        UnicodeError,
        ValueError,
    ):
        raise ValueError("invalid_backup_payload_contract") from None


@dataclass(frozen=True)
class ComponentVolumeSnapshot:
    """One payload held behind a provider-owned read-only quiescence gate."""

    serviceId: str
    serviceVersion: str
    configSchemaVersion: int
    dataSchemaVersion: str
    captureGeneration: str
    volumeId: str
    payload: bytes


class _NoComponents:
    @contextmanager
    def quiesce(self, _deadline):
        yield ()


class BackupBlocked(Exception):
    def __init__(self, blockers):
        self.blockers = blockers


class CoreBackupContract:
    """Creates a redacted, consistent manifest without exporting secret bytes."""

    def __init__(
        self,
        db: Database,
        auth: AuthService,
        settings: Settings,
        *,
        component_boundary=None,
        monotonic=time.monotonic,
    ):
        self.db, self.auth, self.settings = db, auth, settings
        self._component_boundary = component_boundary or _NoComponents()
        self._monotonic = monotonic
        self._export_lock = threading.Lock()

    @staticmethod
    def _catalog_components():
        catalog = load_catalog()
        result = {}
        for entry in catalog.entries:
            manifest = entry.manifest
            volume_ids = tuple(
                sorted(
                    f"component-{manifest.serviceId.replace('_', '-')}-"
                    f"{mount.relativePath.rsplit('/', 1)[-1]}"
                    for mount in manifest.mounts
                    if mount.kind == "managed_appdata"
                )
            )
            result[manifest.serviceId] = {
                "serviceVersion": manifest.version,
                "configSchemaVersion": manifest.configSchemaVersion,
                "dataSchemaVersion": manifest.dataSchemaVersion,
                "volumeResourceIds": volume_ids,
            }
        return result

    @classmethod
    def _component_payloads(cls, snapshots):
        try:
            if type(snapshots) not in (tuple, list) or len(snapshots) > 128:
                raise ValueError("invalid_component_capture")
            catalog = cls._catalog_components()
            grouped = {}
            payloads = {}
            generations = set()
            total = 0
            for snapshot in snapshots:
                if type(snapshot) is not ComponentVolumeSnapshot:
                    raise ValueError("invalid_component_capture")
                expected = catalog.get(snapshot.serviceId)
                resource_id = f"component-{snapshot.volumeId}"
                payload = snapshot.payload
                if (
                    expected is None
                    or snapshot.serviceVersion != expected["serviceVersion"]
                    or snapshot.configSchemaVersion
                    != expected["configSchemaVersion"]
                    or snapshot.dataSchemaVersion != expected["dataSchemaVersion"]
                    or type(snapshot.captureGeneration) is not str
                    or _CAPTURE_GENERATION.fullmatch(snapshot.captureGeneration) is None
                    or resource_id not in expected["volumeResourceIds"]
                    or type(payload) is not bytes
                    or not 1 <= len(payload) <= MAX_COMPONENT_VOLUME_BYTES
                    or resource_id in payloads
                ):
                    raise ValueError("invalid_component_capture")
                total += len(payload)
                if total > MAX_COMPONENT_BYTES:
                    raise ValueError("component_capture_too_large")
                payloads[resource_id] = payload
                generations.add(snapshot.captureGeneration)
                grouped.setdefault(snapshot.serviceId, []).append(resource_id)
            components = []
            for service_id in sorted(grouped):
                expected = catalog[service_id]
                volume_ids = sorted(grouped[service_id])
                if tuple(volume_ids) != expected["volumeResourceIds"]:
                    raise ValueError("incomplete_component_capture")
                components.append(
                    ComponentBackup(
                        serviceId=service_id,
                        serviceVersion=expected["serviceVersion"],
                        configSchemaVersion=expected["configSchemaVersion"],
                        dataSchemaVersion=expected["dataSchemaVersion"],
                        volumeResourceIds=volume_ids,
                    )
                )
            if payloads and len(generations) != 1:
                raise ValueError("mixed_capture_generation")
            return components, payloads, next(iter(generations), None)
        except (AttributeError, TypeError, ValueError):
            raise ApiError("server_unavailable", 503) from None

    @classmethod
    def _component_compatibility(cls, components):
        catalog = cls._catalog_components()
        reasons = []
        for component in components:
            expected = catalog.get(component.serviceId)
            if (
                expected is None
                or component.serviceVersion != expected["serviceVersion"]
            ):
                if "component_version_mismatch" not in reasons:
                    reasons.append("component_version_mismatch")
                continue
            if (
                component.configSchemaVersion != expected["configSchemaVersion"]
                or component.dataSchemaVersion != expected["dataSchemaVersion"]
            ) and "component_schema_mismatch" not in reasons:
                reasons.append("component_schema_mismatch")
            if (
                tuple(component.volumeResourceIds)
                != expected["volumeResourceIds"]
                and "component_volume_mismatch" not in reasons
            ):
                reasons.append("component_volume_mismatch")
        return reasons

    @staticmethod
    def _blockers(connection, now):
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
                f"SELECT 1 FROM {table} WHERE {predicate} LIMIT 1",
                {"now": now},
            ).fetchone()
        ]

    @staticmethod
    def _schema_versions(connection):
        values = {}
        for row in connection.execute(
            "SELECT key,value FROM metadata WHERE key LIKE '%_schema' ORDER BY key"
        ):
            key, raw = row["key"], row["value"]
            if (
                type(key) is not str
                or _SCHEMA_MARKER_KEY.fullmatch(key) is None
                or type(raw) is not str
                or _SCHEMA_MARKER_VALUE.fullmatch(raw) is None
            ):
                raise ValueError("invalid_schema_marker")
            version = int(raw)
            if version > 2**31 - 1:
                raise ValueError("invalid_schema_marker")
            values[key] = version
        return values

    def _capture_vault_key(self, connection) -> bytes:
        try:
            key = private_read(self.settings.key_file, 32)
            stored = connection.execute(
                "SELECT value FROM metadata WHERE key='key_check'"
            ).fetchone()
            expected = hmac.new(
                key, b"larenor-vault-key-check-v1", hashlib.sha256
            ).hexdigest()
            if (
                len(key) != 32
                or stored is None
                or type(stored["value"]) is not str
                or not secrets.compare_digest(stored["value"], expected)
            ):
                raise ValueError("vault_key_mismatch")
            return key
        except (OSError, sqlite3.Error, StartupError, TypeError, ValueError):
            raise ApiError("server_unavailable", 503) from None

    def _capture_family_board(self) -> bytes:
        path = self.settings.data_dir / "family-board.sqlite3"
        checked_path(path)
        if not path.is_file():
            raise ApiError("server_unavailable", 503)
        try:
            with closing(sqlite3.connect(path, timeout=5.0)) as board:
                # Hold this write reservation until both databases have been
                # serialized. Core's reservation is acquired first, matching
                # the family-board authority-then-store lock order.
                board.execute("BEGIN IMMEDIATE")
                page_size = board.execute("PRAGMA page_size").fetchone()[0]
                page_count = board.execute("PRAGMA page_count").fetchone()[0]
                if page_size * page_count > MAX_FAMILY_BOARD_BYTES:
                    raise ApiError("backup_too_large", 413)
                if board.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise ApiError("server_unavailable", 503)
                payload = board.serialize()
                board.rollback()
            if not payload or len(payload) > MAX_FAMILY_BOARD_BYTES:
                raise ApiError("backup_too_large", 413)
            return payload
        except sqlite3.Error:
            raise ApiError("server_unavailable", 503) from None

    def capture(self, actor: Principal) -> BackupCapture:
        with self.db.connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            self.auth.assert_current(connection, actor)
            blockers = self._blockers(connection, self.settings.clock())
            if blockers:
                connection.rollback()
                raise BackupBlocked(blockers)
            schema = int(
                connection.execute(
                    "SELECT value FROM metadata WHERE key='schema_version'"
                ).fetchone()["value"]
            )
            try:
                component_versions = self._schema_versions(connection)
            except (TypeError, ValueError):
                connection.rollback()
                raise ApiError("server_unavailable", 503) from None
            page_bytes = connection.execute("PRAGMA page_size").fetchone()[0]
            page_count = connection.execute("PRAGMA page_count").fetchone()[0]
            if page_bytes * page_count > MAX_DATABASE_BYTES:
                connection.rollback()
                raise ApiError("backup_too_large", 413)
            deadline = self._monotonic() + COMPONENT_QUIESCENCE_SECONDS
            try:
                key = self._capture_vault_key(connection)
                with self._component_boundary.quiesce(deadline) as snapshots:
                    (
                        components,
                        component_payloads,
                        capture_generation,
                    ) = self._component_payloads(snapshots)
                    database = connection.serialize()
                    family_board = self._capture_family_board()
            except BackupBlocked:
                connection.rollback()
                raise
            except ApiError:
                connection.rollback()
                raise
            except (AttributeError, OSError, RuntimeError, TypeError, ValueError):
                connection.rollback()
                raise BackupBlocked(["component_quiescence_unavailable"]) from None
            if self._monotonic() > deadline:
                connection.rollback()
                raise BackupBlocked(["component_quiescence_timeout"])
            connection.rollback()

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
                "contractVersion": 2,
                "schemas": component_versions,
                "components": [
                    component.model_dump(mode="json") for component in components
                ],
            }
        )
        payloads = {
            "core-database": database,
            "family-board": family_board,
            "vault-key": key,
            "core-configuration": configuration,
            "component-index": component_index,
            **component_payloads,
        }
        resources = sorted(
            (
                _resource("core-database", "database", str(schema), database),
                _resource("family-board", "familyBoard", "1", family_board),
                _resource("vault-key", "vaultKey", "aes256-v1", key),
                _resource("core-configuration", "configuration", "1", configuration),
                _resource("component-index", "componentData", "2", component_index),
                *(
                    _resource(
                        identifier,
                        "componentData",
                        "component-v1",
                        payload,
                    )
                    for identifier, payload in component_payloads.items()
                ),
            ),
            key=lambda item: item.id,
        )
        manifest = BackupManifest(
            contractVersion=2,
            snapshotId=capture_generation or secrets.token_hex(16),
            createdAt=int(self.settings.clock()),
            coreVersion=server_version(),
            databaseSchemaVersion=schema,
            componentSchemaVersions=component_versions,
            components=components,
            consistencyBoundary=BackupConsistencyBoundary(
                mode="core_write_lock_and_component_quiescence",
                maxDurationSeconds=COMPONENT_QUIESCENCE_SECONDS,
            ),
            resources=resources,
        )
        return BackupCapture(manifest=manifest, payloads=payloads)

    def plan(self, actor: Principal):
        if not self._export_lock.acquire(blocking=False):
            raise ApiError("backup_busy", 409)
        try:
            try:
                capture = self.capture(actor)
            except BackupBlocked as error:
                return {"status": "blocked", "blockers": error.blockers, "manifest": None}
            return {"status": "ready", "blockers": [], "manifest": capture.manifest}
        finally:
            self._export_lock.release()

    def validate_restore(self, manifest: BackupManifest):
        reasons = []
        if manifest.contractVersion not in (1, 2):
            reasons.append("unsupported_contract_version")
        with self.db.connection() as connection:
            try:
                current_schema = int(
                    connection.execute(
                        "SELECT value FROM metadata WHERE key='schema_version'"
                    ).fetchone()["value"]
                )
                component_versions = self._schema_versions(connection)
            except (sqlite3.Error, TypeError, ValueError):
                raise ApiError("server_unavailable", 503) from None
        if manifest.databaseSchemaVersion != current_schema:
            reasons.append("database_schema_mismatch")
        if manifest.coreVersion != server_version():
            reasons.append("core_version_mismatch")
        if manifest.componentSchemaVersions != component_versions:
            reasons.append("component_schema_mismatch")
        for reason in self._component_compatibility(manifest.components):
            if reason not in reasons:
                reasons.append(reason)
        return {"compatible": not reasons, "reasons": reasons}

    @staticmethod
    def _derive_key(passphrase: str, salt: bytes) -> bytes:
        return Scrypt(salt=salt, length=32, n=2**15, r=8, p=1).derive(
            passphrase.encode("utf-8")
        )

    @staticmethod
    def _archive(capture: BackupCapture) -> bytes:
        output = io.BytesIO()
        manifest = capture.manifest.model_dump(
            mode="json", by_alias=True, exclude_none=True
        )
        if capture.manifest.contractVersion == 1:
            manifest.pop("components", None)
            manifest.pop("consistencyBoundary", None)
        with zipfile.ZipFile(
            output, mode="w", compression=zipfile.ZIP_DEFLATED, compresslevel=6
        ) as archive:
            archive.writestr(
                _MANIFEST_NAME,
                _canonical(manifest),
            )
            for identifier in sorted(capture.payloads):
                archive.writestr(
                    f"resources/{identifier}", capture.payloads[identifier]
                )
        value = output.getvalue()
        if len(value) > MAX_BUNDLE_BYTES - BUNDLE_ENVELOPE_BYTES:
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
        return open_backup_bundle(bundle, passphrase)
