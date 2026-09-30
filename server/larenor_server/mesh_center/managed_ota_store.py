"""Crash-durable authenticated storage for provider-managed OTA intents."""

from __future__ import annotations

import json
import os
from pathlib import Path
import secrets

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import StartupError

MAGIC = b"LARENOR-MANAGED-OTA-1\0"
AAD = b"larenor:managed-ota-state:v1"
MAX_BYTES = 8 * 1024 * 1024


class ManagedOtaStore:
    def __init__(self, path: Path, key: bytes):
        if not isinstance(key, bytes) or len(key) != 32:
            raise ValueError("invalid_key")
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._cipher = AESGCM(key)
        if self.path.exists():
            self.load()

    def load(self):
        if not self.path.exists():
            return {"schemaVersion": 1, "commands": []}
        try:
            payload = self.path.read_bytes()
            start = len(MAGIC)
            if (
                not payload.startswith(MAGIC)
                or len(payload) <= start + 12 + 16
                or len(payload) > MAX_BYTES
            ):
                raise ValueError
            plain = self._cipher.decrypt(
                payload[start : start + 12], payload[start + 12 :], AAD
            )
            value = json.loads(plain)
            if (
                not isinstance(value, dict)
                or value.get("schemaVersion") != 1
                or not isinstance(value.get("commands"), list)
                or set(value) != {"schemaVersion", "commands"}
            ):
                raise ValueError
            return value
        except (InvalidTag, OSError, UnicodeError, ValueError, TypeError, json.JSONDecodeError):
            raise StartupError("mesh_managed_ota_storage_invalid") from None

    def save(self, value):
        temporary = None
        try:
            plain = json.dumps(
                value, sort_keys=True, separators=(",", ":"), allow_nan=False
            ).encode("utf-8")
            if not 1 <= len(plain) <= MAX_BYTES:
                raise ValueError
            nonce = secrets.token_bytes(12)
            payload = MAGIC + nonce + self._cipher.encrypt(nonce, plain, AAD)
            temporary = self.path.with_name(
                f".{self.path.name}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
            )
            descriptor = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
                0o600,
            )
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
        except (OSError, ValueError, TypeError):
            raise StartupError("mesh_managed_ota_storage_invalid") from None
        finally:
            if temporary is not None:
                try:
                    temporary.unlink(missing_ok=True)
                except OSError:
                    pass
