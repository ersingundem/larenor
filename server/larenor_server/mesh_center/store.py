"""Crash-safe encrypted persistence for bounded firmware update state."""

import json
import os
import secrets
from pathlib import Path

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import StartupError

MAGIC = b"LARENOR-MESH-STATE-1\0"
AAD = b"larenor:mesh-update-state:v1"
MAX_STATE_BYTES = 16 * 1024 * 1024


class FirmwareUpdateStore:
    """One authenticated snapshot replaced atomically after every state change."""

    def __init__(self, path: Path, key: bytes):
        if not isinstance(key, bytes) or len(key) != 32:
            raise ValueError("invalid_key")
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._cipher = AESGCM(key)
        if self.path.exists():
            self.load()

    def load(self) -> dict:
        if not self.path.exists():
            return {"schemaVersion": 1, "commands": [], "audit": []}
        try:
            payload = self.path.read_bytes()
            if (
                len(payload) <= len(MAGIC) + 12 + 16
                or len(payload) > MAX_STATE_BYTES
                or not payload.startswith(MAGIC)
            ):
                raise ValueError
            nonce_start = len(MAGIC)
            nonce = payload[nonce_start : nonce_start + 12]
            plain = self._cipher.decrypt(nonce, payload[nonce_start + 12 :], AAD)
            value = json.loads(plain)
            if (
                not isinstance(value, dict)
                or value.get("schemaVersion") != 1
                or not isinstance(value.get("commands"), list)
                or not isinstance(value.get("audit"), list)
            ):
                raise ValueError
            return value
        except (
            InvalidTag,
            OSError,
            UnicodeDecodeError,
            ValueError,
            TypeError,
            json.JSONDecodeError,
        ):
            raise StartupError("mesh_update_storage_invalid") from None

    def save(self, value: dict) -> None:
        try:
            plain = json.dumps(value, sort_keys=True, separators=(",", ":")).encode(
                "utf-8"
            )
            if len(plain) > MAX_STATE_BYTES:
                raise ValueError
            nonce = secrets.token_bytes(12)
            payload = MAGIC + nonce + self._cipher.encrypt(nonce, plain, AAD)
            temporary = self.path.with_name(
                f".{self.path.name}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
            )
            descriptor = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            try:
                with os.fdopen(descriptor, "wb") as stream:
                    stream.write(payload)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, self.path)
                os.chmod(self.path, 0o600)
                directory = os.open(self.path.parent, os.O_RDONLY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            finally:
                if temporary.exists():
                    temporary.unlink()
        except (OSError, ValueError, TypeError):
            raise StartupError("mesh_update_storage_invalid") from None
