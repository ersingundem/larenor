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
        )
