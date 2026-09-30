import os
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from .errors import StartupError


@dataclass(frozen=True)
class Settings:
    data_dir: Path
    key_file: Path
    bootstrap_file: Path | None = None
    clock: Callable[[], float] = field(default=time.time, repr=False, compare=False)
    access_ttl_seconds: int = 900
    refresh_ttl_seconds: int = 30 * 24 * 60 * 60
    login_ip_limit: int = 5
    login_account_limit: int = 10
    login_global_limit: int = 30
    plugin_worker_socket: Path | None = None
    plugin_worker_uid: int = 0
    installation_worker_socket: Path | None = None
    installation_worker_uid: int = 0
    proxmox_power_worker_socket: Path | None = None
    proxmox_power_worker_health: Path | None = None
    proxmox_power_worker_uid: int = 0
    keenetic_worker_socket: Path | None = None
    keenetic_worker_health: Path | None = None
    keenetic_worker_key_file: Path | None = None
    keenetic_worker_uid: int = 0
    component_backup_worker_socket: Path | None = None
    component_backup_worker_uid: int = 0
    media_archive_worker_socket: Path | None = None
    media_archive_worker_uid: int = 0
    media_archive_action_worker_socket: Path | None = None
    media_archive_action_worker_uid: int = 0
    media_archive_authority_socket: Path | None = None
    media_archive_socket_gid: int | None = None
    mesh_center_worker_socket: Path | None = None
    mesh_center_worker_uid: int = 0
    mesh_center_worker_socket_gid: int | None = None
    ai_worker_config: Path | None = None
    ai_worker_socket: Path | None = None
    ai_worker_uid: int = 0
    ai_worker_socket_gid: int | None = None
    private_event_ffmpeg: Path | None = None
    private_event_ffprobe: Path | None = None
    home_document_tesseract: Path | None = None
    home_document_pdftoppm: Path | None = None

    def __post_init__(self):
        worker_uids = (
            self.plugin_worker_uid,
            self.installation_worker_uid,
            self.proxmox_power_worker_uid,
            self.keenetic_worker_uid,
            self.component_backup_worker_uid,
            self.media_archive_worker_uid,
            self.media_archive_action_worker_uid,
            self.mesh_center_worker_uid,
            self.ai_worker_uid,
        )
        if any(
            type(value) is not int or not 0 <= value < 2**31
            for value in worker_uids
        ):
            raise ValueError("invalid_worker_configuration")
        if (self.media_archive_socket_gid is not None
                and (type(self.media_archive_socket_gid) is not int
                     or not 0 <= self.media_archive_socket_gid < 2**31)):
            raise ValueError("invalid_worker_configuration")
        if (self.ai_worker_socket_gid is not None
                and (type(self.ai_worker_socket_gid) is not int
                     or not 0 <= self.ai_worker_socket_gid < 2**31)):
            raise ValueError("invalid_worker_configuration")
        if (self.mesh_center_worker_socket_gid is not None
                and (type(self.mesh_center_worker_socket_gid) is not int
                     or not 0 <= self.mesh_center_worker_socket_gid < 2**31)):
            raise ValueError("invalid_worker_configuration")
        if ((self.ai_worker_socket is None) != (self.ai_worker_socket_gid is None)
                or self.ai_worker_socket is not None
                and self.ai_worker_config is not None):
            raise ValueError("invalid_worker_configuration")
        proxmox_paths = (
            self.proxmox_power_worker_socket,
            self.proxmox_power_worker_health,
        )
        if any(path is not None for path in proxmox_paths) and any(
            path is None for path in proxmox_paths
        ):
            raise ValueError("invalid_worker_configuration")
        keenetic_paths = (
            self.keenetic_worker_socket,
            self.keenetic_worker_health,
            self.keenetic_worker_key_file,
        )
        if any(path is not None for path in keenetic_paths) and any(
            path is None for path in keenetic_paths
        ):
            raise ValueError("invalid_worker_configuration")
        paths = (
            self.plugin_worker_socket,
            self.installation_worker_socket,
            *proxmox_paths,
            *keenetic_paths,
            self.component_backup_worker_socket,
            self.media_archive_worker_socket,
            self.media_archive_action_worker_socket,
            self.media_archive_authority_socket,
            self.mesh_center_worker_socket,
            self.ai_worker_config,
            self.ai_worker_socket,
            self.home_document_tesseract,
            self.home_document_pdftoppm,
        )
        for path in paths:
            if path is not None and (
                not isinstance(path, Path)
                or not path.is_absolute()
                or ".." in path.parts
                or any(ord(char) < 32 or ord(char) == 127 for char in str(path))
            ):
                raise ValueError("invalid_worker_configuration")
        configured = [path for path in paths if path is not None]
        if len(set(configured)) != len(configured):
            raise ValueError("invalid_worker_configuration")
        if any(path == self.key_file for path in configured):
            raise ValueError("invalid_worker_configuration")
        if any(path.is_relative_to(self.data_dir) for path in keenetic_paths if path):
            raise ValueError("invalid_worker_configuration")
        if (
            self.component_backup_worker_socket is None
            and self.component_backup_worker_uid != 0
        ):
            raise ValueError("invalid_worker_configuration")
        if (
            (
                self.media_archive_worker_socket is None
                and self.media_archive_worker_uid != 0
            )
            or (
                self.media_archive_action_worker_socket is None
                and self.media_archive_action_worker_uid != 0
            )
        ):
            raise ValueError("invalid_worker_configuration")
        if ((self.mesh_center_worker_socket is None)
                != (self.mesh_center_worker_socket_gid is None)
                or self.mesh_center_worker_socket is None
                and self.mesh_center_worker_uid != 0):
            raise ValueError("invalid_worker_configuration")
        if (self.media_archive_authority_socket is not None
                and (self.media_archive_worker_socket is None
                     or self.media_archive_action_worker_socket is None)):
            raise ValueError("invalid_worker_configuration")
        if (self.media_archive_socket_gid is not None
                and (self.media_archive_authority_socket is None
                     or self.media_archive_worker_socket is None
                     or self.media_archive_action_worker_socket is None)):
            raise ValueError("invalid_worker_configuration")
        redaction_binaries = (self.private_event_ffmpeg, self.private_event_ffprobe)
        if any(value is None for value in redaction_binaries) and any(
            value is not None for value in redaction_binaries
        ):
            raise ValueError("invalid_private_event_configuration")
        document_ocr = (
            self.home_document_tesseract,
            self.home_document_pdftoppm,
        )
        if any(value is None for value in document_ocr) and any(
            value is not None for value in document_ocr
        ):
            raise ValueError("invalid_home_document_ocr_configuration")
        if any(
            not isinstance(value, Path)
            or not value.is_absolute()
            or ".." in value.parts
            or any(ord(char) < 32 or ord(char) == 127 for char in str(value))
            for value in redaction_binaries
            if value is not None
        ) or (
            self.private_event_ffmpeg is not None
            and self.private_event_ffmpeg == self.private_event_ffprobe
        ):
            raise ValueError("invalid_private_event_configuration")

    @property
    def database_file(self) -> Path:
        return self.data_dir / "larenor.sqlite3"

    @property
    def effective_bootstrap_file(self) -> Path:
        return self.bootstrap_file or self.data_dir / "bootstrap-admin.txt"

    @classmethod
    def from_environment(cls) -> "Settings":
        try:
            return cls(
                data_dir=Path(os.environ.get("LARENOR_DATA_DIR", "/data")),
                key_file=Path(os.environ.get("LARENOR_KEY_FILE", "/secrets/vault.key")),
                plugin_worker_socket=Path(os.environ["LARENOR_PLUGIN_WORKER_SOCKET"]) if os.environ.get("LARENOR_PLUGIN_WORKER_SOCKET") else None,
                plugin_worker_uid=int(os.environ.get("LARENOR_PLUGIN_WORKER_UID", "0")),
                installation_worker_socket=Path(os.environ["LARENOR_INSTALLATION_WORKER_SOCKET"]
                                                ) if os.environ.get("LARENOR_INSTALLATION_WORKER_SOCKET") else None,
                installation_worker_uid=int(os.environ.get("LARENOR_INSTALLATION_WORKER_UID", "0")),
                proxmox_power_worker_socket=Path(os.environ["LARENOR_PROXMOX_POWER_WORKER_SOCKET"]
                                                 ) if os.environ.get("LARENOR_PROXMOX_POWER_WORKER_SOCKET") else None,
                proxmox_power_worker_health=Path(os.environ["LARENOR_PROXMOX_POWER_WORKER_HEALTH"]
                                                 ) if os.environ.get("LARENOR_PROXMOX_POWER_WORKER_HEALTH") else None,
                proxmox_power_worker_uid=int(os.environ.get("LARENOR_PROXMOX_POWER_WORKER_UID", "0")),
                keenetic_worker_socket=(
                    Path(os.environ["LARENOR_KEENETIC_WORKER_SOCKET"])
                    if os.environ.get("LARENOR_KEENETIC_WORKER_SOCKET") else None
                ),
                keenetic_worker_health=(
                    Path(os.environ["LARENOR_KEENETIC_WORKER_HEALTH"])
                    if os.environ.get("LARENOR_KEENETIC_WORKER_HEALTH") else None
                ),
                keenetic_worker_key_file=(
                    Path(os.environ["LARENOR_KEENETIC_WORKER_KEY_FILE"])
                    if os.environ.get("LARENOR_KEENETIC_WORKER_KEY_FILE") else None
                ),
                keenetic_worker_uid=int(
                    os.environ.get("LARENOR_KEENETIC_WORKER_UID", "0")
                ),
                component_backup_worker_socket=(
                    Path(os.environ["LARENOR_COMPONENT_BACKUP_WORKER_SOCKET"])
                    if os.environ.get("LARENOR_COMPONENT_BACKUP_WORKER_SOCKET")
                    else None
                ),
                component_backup_worker_uid=int(
                    os.environ.get("LARENOR_COMPONENT_BACKUP_WORKER_UID", "0")
                ),
                media_archive_worker_socket=(
                    Path(os.environ["LARENOR_MEDIA_ARCHIVE_WORKER_SOCKET"])
                    if os.environ.get("LARENOR_MEDIA_ARCHIVE_WORKER_SOCKET")
                    else None
                ),
                media_archive_worker_uid=int(
                    os.environ.get("LARENOR_MEDIA_ARCHIVE_WORKER_UID", "0")
                ),
                media_archive_action_worker_socket=(
                    Path(os.environ["LARENOR_MEDIA_ARCHIVE_ACTION_WORKER_SOCKET"])
                    if os.environ.get(
                        "LARENOR_MEDIA_ARCHIVE_ACTION_WORKER_SOCKET")
                    else None
                ),
                media_archive_action_worker_uid=int(os.environ.get(
                    "LARENOR_MEDIA_ARCHIVE_ACTION_WORKER_UID", "0"
                )),
                media_archive_authority_socket=(
                    Path(os.environ["LARENOR_MEDIA_ARCHIVE_AUTHORITY_SOCKET"])
                    if os.environ.get("LARENOR_MEDIA_ARCHIVE_AUTHORITY_SOCKET")
                    else None
                ),
                media_archive_socket_gid=(
                    int(os.environ["LARENOR_MEDIA_ARCHIVE_SOCKET_GID"])
                    if os.environ.get("LARENOR_MEDIA_ARCHIVE_SOCKET_GID")
                    else None
                ),
                mesh_center_worker_socket=(
                    Path(os.environ["LARENOR_MESH_WORKER_SOCKET"])
                    if os.environ.get("LARENOR_MESH_WORKER_SOCKET")
                    else None
                ),
                mesh_center_worker_uid=int(
                    os.environ.get("LARENOR_MESH_WORKER_UID", "0")
                ),
                mesh_center_worker_socket_gid=(
                    int(os.environ["LARENOR_MESH_WORKER_SOCKET_GID"])
                    if os.environ.get("LARENOR_MESH_WORKER_SOCKET_GID") else None
                ),
                ai_worker_config=(
                    Path(os.environ["LARENOR_AI_WORKER_CONFIG"])
                    if os.environ.get("LARENOR_AI_WORKER_CONFIG") else None
                ),
                ai_worker_socket=(
                    Path(os.environ["LARENOR_AI_WORKER_SOCKET"])
                    if os.environ.get("LARENOR_AI_WORKER_SOCKET") else None
                ),
                ai_worker_uid=int(os.environ.get("LARENOR_AI_WORKER_UID", "0")),
                ai_worker_socket_gid=(
                    int(os.environ["LARENOR_AI_WORKER_SOCKET_GID"])
                    if os.environ.get("LARENOR_AI_WORKER_SOCKET_GID") else None
                ),
                home_document_tesseract=(
                    Path(os.environ["LARENOR_HOME_DOCUMENT_TESSERACT"])
                    if os.environ.get("LARENOR_HOME_DOCUMENT_TESSERACT") else None
                ),
                home_document_pdftoppm=(
                    Path(os.environ["LARENOR_HOME_DOCUMENT_PDFTOPPM"])
                    if os.environ.get("LARENOR_HOME_DOCUMENT_PDFTOPPM") else None
                ),
                private_event_ffmpeg=(
                    Path(os.environ["LARENOR_PRIVATE_EVENT_FFMPEG"])
                    if os.environ.get("LARENOR_PRIVATE_EVENT_FFMPEG") else None
                ),
                private_event_ffprobe=(
                    Path(os.environ["LARENOR_PRIVATE_EVENT_FFPROBE"])
                    if os.environ.get("LARENOR_PRIVATE_EVENT_FFPROBE") else None
                ),
            )
        except ValueError:
            # int() errors include their input. Environment values must never
            # escape through the CLI or another configured-app entry point.
            raise StartupError("invalid_worker_configuration") from None
