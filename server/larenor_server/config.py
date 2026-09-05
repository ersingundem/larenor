from dataclasses import dataclass, field
import os
from pathlib import Path
import time
from typing import Callable


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

    def __post_init__(self):
        if type(self.plugin_worker_uid) is not int or not 0 <= self.plugin_worker_uid < 2**31:
            raise ValueError("invalid_worker_configuration")
        if self.plugin_worker_socket is not None and (
                not isinstance(self.plugin_worker_socket, Path) or not self.plugin_worker_socket.is_absolute()
                or ".." in self.plugin_worker_socket.parts):
            raise ValueError("invalid_worker_configuration")

    @property
    def database_file(self) -> Path:
        return self.data_dir / "larenor.sqlite3"

    @property
    def effective_bootstrap_file(self) -> Path:
        return self.bootstrap_file or self.data_dir / "bootstrap-admin.txt"

    @classmethod
    def from_environment(cls) -> "Settings":
        return cls(
            data_dir=Path(os.environ.get("LARENOR_DATA_DIR", "/data")),
            key_file=Path(os.environ.get("LARENOR_KEY_FILE", "/secrets/vault.key")),
            plugin_worker_socket=Path(os.environ["LARENOR_PLUGIN_WORKER_SOCKET"]) if os.environ.get("LARENOR_PLUGIN_WORKER_SOCKET") else None,
            plugin_worker_uid=int(os.environ.get("LARENOR_PLUGIN_WORKER_UID", "0")),
        )
