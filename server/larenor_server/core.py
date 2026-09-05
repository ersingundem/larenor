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
from .database import Database
from .errors import StartupError
from .files import checked_path, private_create, private_directory, private_read, sync_directory
from .plugins.schema import migrate_plugins
from .plugins.service import PluginManagement
from .plugins.job_schema import migrate_plugin_jobs
from .plugins.jobs import JobManagement
from .plugins.preflight_ipc import PreflightWorkerClient
from .services.schema import migrate_services
from .services.service import ServiceManagement
from .services.probe_runner import ServiceProbeRunner
from .vault import VaultService


class CoreServices:
    def __init__(self, settings: Settings):
        self.settings = settings
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
                    if version["value"] not in ("1", "2") or not stored_key or not hmac.compare_digest(stored_key["value"], check) or not users:
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
                migrate_services(connection)
                migrate_plugins(connection)
                migrate_plugin_jobs(connection)
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
            self.admin = AdminService(self.db, self.auth, settings)
            self.services = ServiceManagement(self.db, self.auth, settings, key)
            self.services.validate_storage()
            self.service_probe = ServiceProbeRunner(self.services)
            self.plugins = PluginManagement(self.db, self.auth, settings, key)
            self.plugins.validate_storage()
            backend = None if settings.plugin_worker_socket is None else PreflightWorkerClient(
                settings.plugin_worker_socket, owner_uid=settings.plugin_worker_uid)
            self.plugin_jobs = JobManagement(self.db, self.auth, settings, key, self.plugins, backend)
            self.plugin_jobs.validate_storage()
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
