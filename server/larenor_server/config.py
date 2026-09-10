from dataclasses import dataclass, field
import os
from pathlib import Path
import time
from typing import Callable

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
    music_playback_worker_socket: Path | None = None
    music_playback_worker_uid: int = 0

    def __post_init__(self):
        if (type(self.plugin_worker_uid) is not int or not 0 <= self.plugin_worker_uid < 2**31
                or type(self.installation_worker_uid) is not int
                or not 0 <= self.installation_worker_uid < 2**31
                or type(self.music_playback_worker_uid) is not int
                or not 0 <= self.music_playback_worker_uid < 2**31):
            raise ValueError("invalid_worker_configuration")
        paths = (self.plugin_worker_socket, self.installation_worker_socket,
                 self.music_playback_worker_socket)
        for path in paths:
            if path is not None and (not isinstance(path, Path) or not path.is_absolute()
                    or ".." in path.parts or any(ord(char) < 32 or ord(char) == 127 for char in str(path))):
                raise ValueError("invalid_worker_configuration")
        configured = [path for path in paths if path is not None]
        if len(set(configured)) != len(configured):
            raise ValueError("invalid_worker_configuration")

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
                music_playback_worker_socket=Path(
                    os.environ["LARENOR_MUSIC_PLAYBACK_WORKER_SOCKET"]
                ) if os.environ.get(
                    "LARENOR_MUSIC_PLAYBACK_WORKER_SOCKET") else None,
                music_playback_worker_uid=int(os.environ.get(
                    "LARENOR_MUSIC_PLAYBACK_WORKER_UID", "0")),
            )
        except ValueError:
            # int() errors include their input. Environment values must never
            # escape through the CLI or another configured-app entry point.
            raise StartupError("invalid_worker_configuration") from None
