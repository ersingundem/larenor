import datetime
import json
import math
import re
import secrets

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from .auth import AuthService, Principal
from .config import Settings
from .database import Database
from .errors import ApiError


MAX_JSON_BYTES = 2 * 1024 * 1024


def validate_json_bounds(value: object) -> None:
    stack = [(value, 1)]
    keys = nodes = 0
    while stack:
        item, depth = stack.pop()
        nodes += 1
        if depth > 16 or nodes > 40000:
            raise ApiError("invalid_request")
        if isinstance(item, dict):
            keys += len(item)
            if keys > 10000:
                raise ApiError("invalid_request")
            for key, child in item.items():
                if not isinstance(key, str) or len(key.encode("utf-8")) > 65536:
                    raise ApiError("invalid_request")
                stack.append((child, depth + 1))
        elif isinstance(item, list):
            if len(item) > 10000:
                raise ApiError("invalid_request")
            stack.extend((child, depth + 1) for child in item)
        elif isinstance(item, str):
            if len(item.encode("utf-8")) > 65536:
                raise ApiError("invalid_request")
        elif isinstance(item, float):
            if not math.isfinite(item):
                raise ApiError("invalid_request")
        elif item is not None and type(item) not in (int, bool):
            raise ApiError("invalid_request")


def validate_document(document: object) -> bytes:
    validate_json_bounds(document)
    if not isinstance(document, dict) or set(document) != {"version", "snapshot"} or type(document["version"]) is not int or document["version"] != 1:
        raise ApiError("invalid_request")
    snapshot = document["snapshot"]
    if (not isinstance(snapshot, dict) or set(snapshot) != {"version", "createdAt", "groups"} or
            type(snapshot["version"]) is not int or snapshot["version"] != 2 or
            not isinstance(snapshot["createdAt"], str) or len(snapshot["createdAt"]) > 40):
        raise ApiError("invalid_request")
    try:
        datetime.datetime.fromisoformat(snapshot["createdAt"].replace("Z", "+00:00"))
    except ValueError:
        raise ApiError("invalid_request") from None
    groups = snapshot["groups"]
    if (not isinstance(groups, dict) or not set(groups) <= {"privacy", "settings", "dashboard", "connections"} or
            "privacy" not in groups or not set(groups) - {"privacy"} or
            any(not isinstance(group, dict) for group in groups.values())):
        raise ApiError("invalid_request")
    privacy = groups["privacy"]
    if (set(privacy) != {"version", "entityIds", "reviewRequired"} or
            type(privacy["version"]) is not int or privacy["version"] != 1 or
            type(privacy["reviewRequired"]) is not bool or not isinstance(privacy["entityIds"], list)):
        raise ApiError("invalid_request")
    ids = privacy["entityIds"]
    if (len(ids) > 256 or any(not isinstance(item, str) or len(item) > 255 or
                            not re.fullmatch(r"sensor\.[a-z0-9_]+", item) for item in ids) or len(set(ids)) != len(ids)):
        raise ApiError("invalid_request")
    # Full, evolving per-setting/connection validation remains in the Client's
    # BackupSnapshot parser before preview/apply. The server never applies it.
    try:
        encoded = json.dumps(document, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode()
    except (ValueError, UnicodeError):
        raise ApiError("invalid_request") from None
    if len(encoded) > MAX_JSON_BYTES:
        raise ApiError("payload_too_large", 413)
    return encoded


class VaultService:
    def __init__(self, db: Database, auth: AuthService, settings: Settings, key: bytes):
        self.db, self.auth, self.settings = db, auth, settings
        self._cipher = AESGCM(key)

    @staticmethod
    def _aad(user_id: str, revision: int) -> bytes:
        return f"larenor:vault:schema=1:user={user_id}:revision={revision}".encode("ascii")

    def get(self, principal: Principal) -> dict:
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self.auth.assert_current(connection, principal)
            row = connection.execute("SELECT * FROM vaults WHERE user_id=?", (principal.id,)).fetchone()
            if not row:
                return {"revision": 0, "document": None}
            try:
                plaintext = self._cipher.decrypt(row["nonce"], row["ciphertext"], self._aad(principal.id, row["revision"]))
                document = json.loads(plaintext)
                validate_document(document)
            except (InvalidTag, ValueError, UnicodeError, ApiError):
                raise ApiError("vault_unavailable", 503) from None
            return {"revision": row["revision"], "document": document}

    def put(self, principal: Principal, expected_revision: int, document: object) -> dict:
        plaintext = validate_document(document)
        with self.db.transaction() as connection:
            self.auth.assert_current(connection, principal)
            row = connection.execute("SELECT revision FROM vaults WHERE user_id=?", (principal.id,)).fetchone()
            current = row["revision"] if row else 0
            if expected_revision != current:
                raise ApiError("revision_conflict", 409)
            revision = current + 1
            nonce = secrets.token_bytes(12)
            ciphertext = self._cipher.encrypt(nonce, plaintext, self._aad(principal.id, revision))
            connection.execute(
                "INSERT INTO vaults VALUES(?,?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET "
                "revision=excluded.revision,nonce=excluded.nonce,ciphertext=excluded.ciphertext,updated_at=excluded.updated_at",
                (principal.id, revision, nonce, ciphertext, self.settings.clock()),
            )
        return {"revision": revision, "document": json.loads(plaintext)}
