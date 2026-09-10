import fcntl
import hashlib
import hmac
import os
import re
import secrets
import sqlite3
import stat
import uuid

from .admin.service import AdminService
from .auth import AuthService
from .config import Settings
from .context import migrate_context
from .database import Database
from .errors import StartupError
from .files import checked_path, private_create, private_directory, private_read, sync_directory
from .plugins.schema import migrate_plugins
from .plugins.service import PluginManagement
from .plugins.job_schema import migrate_plugin_jobs
from .plugins.jobs import JobManagement
from .plugins.media_schema import migrate_media_preparations
from .plugins.media_preparations import MediaPreparationManagement
from .plugins.media_inspection_schema import migrate_media_inspections
from .plugins.media_inspections import MediaInspectionManagement
from .plugins.media_installation_schema import migrate_media_installations
from .plugins.media_installations import MediaInstallationManagement
from .plugins.media_service_bootstrap_schema import migrate_media_service_bootstraps
from .plugins.media_service_bootstraps import MediaServiceBootstrapManagement
from .plugins.qbittorrent_config_job_schema import migrate_qbittorrent_configurations
from .plugins.qbittorrent_config_jobs import QbittorrentConfigurationManagement
from .plugins.arr_config_job_schema import migrate_arr_configurations
from .plugins.arr_config_jobs import ArrConfigurationManagement
from .plugins.music_assistant_core_schema import migrate_music_assistant_core
from .plugins.music_assistant_core import MusicAssistantCoreManagement
from .plugins.music_provider_setup_schema import migrate_music_provider_setups
from .plugins.music_provider_setups import MusicProviderSetupManagement
from .plugins.music_provider_command_schema import migrate_music_provider_commands
from .plugins.music_provider_commands import MusicProviderCommandManagement
from .plugins.music_playback_schema import migrate_music_playback
from .plugins.music_playback import MusicPlaybackManagement
from .plugins.preflight_ipc import PreflightWorkerClient
from .plugins.installation_ipc import InstallationWorkerClient
from .component_egress.storage import migrate as migrate_component_egress
from .component_egress.service import ComponentEgress
from .services.schema import migrate_services
from .services.service import ServiceManagement
from .services.probe_runner import ServiceProbeRunner
from .vault import VaultService
from .home_resources.schema import migrate_home_resources
from .home_assistant.command_chain import migrate_command_history
from .home_resources.service import HomeResourceRegistry
from .bounded_transfer.models import TransferLimits
from .bounded_transfer.service import BlobProvider, BoundedTransferService
from .home_people.schema import migrate_home_people
from .home_people.service import HomePeopleRegistry
from .home_assistant.schema import migrate_home_assistant
from .home_assistant.service import HomeAssistantAdapter
from .keenetic_resources.schema import migrate as migrate_keenetic_resources
from .keenetic_resources.service import KeeneticResourceAdapter
from .home_assistant.migration_schema import migrate as migrate_direct_ha
from .home_assistant.migration import DirectHaMigration
from .proxmox.schema import migrate as migrate_proxmox_resources
from .proxmox.service import ProxmoxResourceAdapter


class CoreServices:
    def __init__(self, settings: Settings, *, blob_provider: BlobProvider | None = None,
                 transfer_limits: TransferLimits | None = None):
        self.settings = settings
        self._blob_provider = blob_provider
        self._transfer_limits = transfer_limits
        self.bootstrap_created = False
        self.bootstrap_cleanup_pending = False
        try:
            self._initialize()
        except StartupError:
            raise
        except (OSError, ValueError, sqlite3.Error):
            raise StartupError("storage_initialization_failed") from None

    def _initialize(self) -> None:
        settings = self.settings
        private_directory(settings.data_dir)
        checked_path(settings.key_file)
        checked_path(settings.effective_bootstrap_file)
        checked_path(settings.database_file)
        if settings.key_file.is_relative_to(settings.data_dir):
            raise StartupError("vault_key_must_be_outside_data_directory")
        lock_path = settings.data_dir / ".initialize.lock"
        try:
            private_create(lock_path, b"")
        except FileExistsError:
            private_read(lock_path, 0)
        with lock_path.open("rb") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            existed = settings.database_file.exists()
            initialized_marker = settings.data_dir / ".initialized"
            if not existed and initialized_marker.exists():
                raise StartupError("initialized_database_missing")
            if not settings.key_file.exists():
                if existed:
                    raise StartupError("vault_key_missing")
                private_create(settings.key_file, secrets.token_bytes(32))
            key = private_read(settings.key_file, 32)
            if len(key) != 32:
                raise StartupError("vault_key_invalid")
            # An independently backed-up DB must never silently acquire a new key.
            check = hmac.new(key, b"larenor-vault-key-check-v1", hashlib.sha256).hexdigest()
            if existed:
                info = settings.database_file.stat()
                if info.st_nlink == 2:
                    # Recover a crash between publishing the committed DB with
                    # link(2) and removing that one initialization alias.
                    aliases = []
                    for candidate in settings.data_dir.iterdir():
                        if not re.fullmatch(r"\.initialize-[0-9a-f]{32}\.sqlite3", candidate.name):
                            continue
                        entry = candidate.lstat()
                        if (stat.S_ISREG(entry.st_mode) and entry.st_uid == os.geteuid()
                                and entry.st_ino == info.st_ino and entry.st_dev == info.st_dev):
                            aliases.append(candidate)
                    if len(aliases) == 1:
                        aliases[0].unlink()
                        sync_directory(settings.data_dir)
                        info = settings.database_file.stat()
                if info.st_uid != os.geteuid() or info.st_mode & 0o777 != 0o600 or info.st_nlink != 1:
                    raise StartupError("storage_file_not_private")
                self.db = Database(settings.database_file)
            else:
                pending_file = settings.data_dir / f".initialize-{uuid.uuid4().hex}.sqlite3"
                private_create(pending_file, b"")
                self.db = Database(pending_file)
                self.db.create_schema()
            self.auth = AuthService(self.db, settings, key)
            with self.db.transaction() as connection:
                version = connection.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()
                stored_key = connection.execute("SELECT value FROM metadata WHERE key='key_check'").fetchone()
                users = connection.execute("SELECT * FROM users").fetchall()
                if version:
                    if version["value"] not in ("1", "2", "3") or not stored_key or not hmac.compare_digest(stored_key["value"], check) or not users:
                        raise StartupError("existing_database_invalid_or_wrong_key")
                    if version["value"] == "1":
                        self.db.migrate_v1(connection)
                else:
                    if existed or users or stored_key:
                        raise StartupError("existing_database_invalid")
                    path = settings.effective_bootstrap_file
                    if path.exists():
                        bootstrap = private_read(path, 2048).decode("ascii")
                        prefix = "username: admin\npassword: "
                        if not bootstrap.startswith(prefix) or not bootstrap.endswith("\n"):
                            raise StartupError("bootstrap_file_invalid")
                        password = bootstrap[len(prefix):-1]
                        if len(password) != 43 or any(char not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-" for char in password):
                            raise StartupError("bootstrap_file_invalid")
                    else:
                        password = secrets.token_urlsafe(32)
                        private_create(path, f"username: admin\npassword: {password}\n".encode("ascii"))
                        self.bootstrap_created = True
                    connection.execute("INSERT INTO users(id,username,role,password_hash,must_change_password,created_at) VALUES(?,?,?,?,?,?)",
                                       (uuid.uuid4().hex, "admin", "admin", self.auth.hash_password(password), 1, settings.clock()))
                    connection.executemany("INSERT INTO metadata VALUES(?,?)", [("schema_version", "2"), ("key_check", check)])
                self.context = migrate_context(connection, key)
                migrate_home_resources(connection, self.context, key)
                migrate_home_people(connection, self.context, key)
                migrate_services(connection)
                migrate_component_egress(connection, self.context, key)
                migrate_home_assistant(connection, self.context, key)
                migrate_keenetic_resources(connection, self.context, key)
                migrate_command_history(connection, self.context, key)
                migrate_direct_ha(connection, key, self.context)
                migrate_proxmox_resources(connection, self.context, key)
                migrate_plugins(connection)
                migrate_plugin_jobs(connection)
                migrate_media_preparations(connection)
                migrate_media_inspections(connection)
                migrate_media_installations(connection)
                migrate_media_service_bootstraps(connection)
                migrate_qbittorrent_configurations(connection)
                migrate_arr_configurations(connection)
                migrate_music_assistant_core(connection)
                migrate_music_provider_setups(connection)
                migrate_music_provider_commands(connection)
                migrate_music_playback(connection)
            if not existed:
                # Only publish the DB after its complete first transaction commits.
                # Never expose an empty DB that a restart might treat as a reset.
                with self.db.connection() as connection:
                    if connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0] != 0:
                        raise StartupError("initial_database_checkpoint_failed")
                os.link(pending_file, settings.database_file)
                pending_file.unlink()
                sync_directory(settings.data_dir)
                self.db = Database(settings.database_file)
                self.auth.db = self.db
            # This is a stable initialization sentinel, not the migrated DB version.
            if not initialized_marker.exists():
                private_create(initialized_marker, b"larenor-schema-1\n")
            else:
                if private_read(initialized_marker, 64) != b"larenor-schema-1\n":
                    raise StartupError("initialized_marker_invalid")
            self.vault = VaultService(self.db, self.auth, settings, key)
            self.home_resources = HomeResourceRegistry(self.db, self.auth, settings, key, self.context)
            self.home_resources.validate_storage()
            self.bounded_transfers = BoundedTransferService(
                self.home_resources, settings, self._blob_provider, self._transfer_limits)
            self.home_people = HomePeopleRegistry(self.db, self.auth, settings, key, self.context)
            self.home_people.validate_storage()
            self.admin = AdminService(self.db, self.auth, settings)
            self.services = ServiceManagement(self.db, self.auth, settings, key)
            self.services.validate_storage()
            self.home_assistant = HomeAssistantAdapter(self.db, self.auth, settings, key, self.home_resources, self.services)
            self.home_assistant.validate_storage()
            self.keenetic_resources = KeeneticResourceAdapter(
                self.db, self.auth, settings, key, self.home_resources, self.services)
            self.keenetic_resources.validate_storage()
            self.direct_ha_migration = DirectHaMigration(self.home_assistant)
            self.direct_ha_migration.validate_storage()
            self.proxmox = ProxmoxResourceAdapter(
                self.db, self.auth, settings, key, self.home_resources, self.services)
            self.proxmox.validate_storage()
            self.component_egress = ComponentEgress(self.services, key, self.context)
            self.services.component_egress = self.component_egress
            self.service_probe = ServiceProbeRunner(self.services)
            self.plugins = PluginManagement(self.db, self.auth, settings, key)
            self.plugins.validate_storage()
            backend = None if settings.plugin_worker_socket is None else PreflightWorkerClient(
                settings.plugin_worker_socket, owner_uid=settings.plugin_worker_uid)
            self.plugin_jobs = JobManagement(self.db, self.auth, settings, key, self.plugins, backend)
            self.plugin_jobs.validate_storage()
            self.media_preparations = MediaPreparationManagement(self.db, self.auth, settings, key, self.plugins, self.context)
            self.media_preparations.validate_storage()
            self.media_inspections = MediaInspectionManagement(self.db, self.auth, settings, key, self.media_preparations, backend)
            self.media_inspections.validate_storage()
            # Mutating execution uses a separate, future worker channel. The
            # read-only preflight socket can never be promoted implicitly.
            installation_backend = None if settings.installation_worker_socket is None else InstallationWorkerClient(
                settings.installation_worker_socket, owner_uid=settings.installation_worker_uid)
            self.media_installations = MediaInstallationManagement(
                self.db, self.auth, settings, key, self.media_preparations, self.media_inspections,
                installation_backend)
            self.media_installations.validate_storage()
            self.media_service_bootstraps = MediaServiceBootstrapManagement(
                self.db, self.auth, settings, key, self.media_installations,
                installation_backend)
            self.media_service_bootstraps.validate_storage()
            self.qbittorrent_configurations = QbittorrentConfigurationManagement(
                self.db, self.auth, settings, key, self.media_installations,
                installation_backend)
            self.qbittorrent_configurations.validate_storage()
            self.arr_configurations = ArrConfigurationManagement(
                self.db, self.auth, settings, key, self.media_installations,
                installation_backend, self.qbittorrent_configurations)
            self.arr_configurations.validate_storage()
            self.music_assistant_core = MusicAssistantCoreManagement(
                self.db, self.auth, settings, key, self.media_installations,
                self.services)
            self.music_assistant_core.validate_storage()
            self.music_provider_setups = MusicProviderSetupManagement(
                self.db, self.auth, settings, key, self.media_installations,
                self.music_assistant_core, installation_backend)
            self.music_provider_setups.validate_storage()
            self.music_provider_commands = MusicProviderCommandManagement(
                self.db, settings, self.music_provider_setups)
            self.music_playback = MusicPlaybackManagement(
                self.db, self.auth, settings, key, self.music_assistant_core,
                self.music_provider_setups, installation_backend)
            self.music_playback.validate_storage()
            self.clear_inactive_bootstrap()

    def clear_inactive_bootstrap(self) -> None:
        path = self.settings.effective_bootstrap_file
        if not path.exists():
            return
        with self.db.connection() as connection:
            admin = connection.execute("SELECT must_change_password FROM users WHERE username='admin'").fetchone()
        if admin and not admin["must_change_password"]:
            private_read(path, 2048)
            path.unlink()
            sync_directory(path.parent)
