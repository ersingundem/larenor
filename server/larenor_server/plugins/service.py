"""Persist expiring, actor-bound configuration previews without host access.

This first API slice intentionally has no worker, queue, confirmation or install
side effect. A preview calculates packaged requirements for a selected platform.
It does not reserve resources or establish that those requirements are available.
"""

import json
import re
import secrets
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..admin.service import utc
from ..auth import AuthService, Principal
from ..config import Settings
from ..database import Database
from ..errors import ApiError, StartupError
from .api_models import PluginPreviewRequest
from .catalog import load_catalog, plan
from .models import InstallPlan


MAX_PREVIEWS = 128
PREVIEW_TTL = 600


class PluginManagement:
    def __init__(self, db: Database, auth: AuthService, settings: Settings, key: bytes):
        self.db, self.auth, self.settings = db, auth, settings
        self._cipher = AESGCM(key)
        try:
            self._catalog = load_catalog()
        except (ValueError, OSError):
            raise StartupError("invalid_plugin_catalog") from None

    def _assert_admin(self, connection, actor: Principal) -> int:
        self.auth.assert_current(connection, actor)
        if actor.must_change_password:
            raise ApiError("password_change_required", 403)
        if actor.role != "admin":
            raise ApiError("forbidden", 403)
        return connection.execute("SELECT revision FROM users WHERE id=?", (actor.id,)).fetchone()[0]

    @staticmethod
    def _aad(row) -> bytes:
        # Bind every routing/authorization/lifetime column; no metadata can be
        # rebound while preserving a valid encrypted plan from another preview.
        binding = {key: row[key] for key in ("id", "revision", "actor_id", "actor_revision",
                                           "family_id", "created_at", "expires_at")}
        return b"larenor:plugins:schema=1:preview:" + json.dumps(
            binding, sort_keys=True, separators=(",", ":")).encode("ascii")

    def _decode(self, row) -> InstallPlan:
        try:
            if (len(row["nonce"]) != 12 or len(row["ciphertext"]) > 32768 or
                    row["revision"] != 1 or row["actor_revision"] < 1 or
                    row["expires_at"] != row["created_at"] + PREVIEW_TTL or
                    any(not re.fullmatch(r"[0-9a-f]{32}", row[key]) for key in ("id", "actor_id", "family_id"))):
                raise ValueError()
            raw = self._cipher.decrypt(row["nonce"], row["ciphertext"], self._aad(row))
            return InstallPlan.model_validate_json(raw)
        except (InvalidTag, ValueError, TypeError):
            raise ApiError("plugin_storage_unavailable", 503) from None

    @staticmethod
    def _public(row, calculated: InstallPlan) -> dict:
        return {"preview": {"id": row["id"], "revision": row["revision"],
                            "createdAt": utc(row["created_at"]), "expiresAt": utc(row["expires_at"]),
                            "plan": calculated}}

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute("SELECT * FROM plugin_previews LIMIT ?", (MAX_PREVIEWS + 1,)).fetchall()
                if len(rows) > MAX_PREVIEWS:
                    raise ApiError("plugin_storage_unavailable", 503)
                for row in rows:
                    self._decode(row)
        except ApiError:
            raise StartupError("invalid_plugins_storage") from None

    def catalog(self, actor: Principal) -> dict:
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            return {"catalogDigest": self._catalog.digest,
                    "entries": list(self._catalog.entries),
                    "worker": {"available": False, "platform": None, "reason": "worker_not_configured"}}

    def preview(self, actor: Principal, body: PluginPreviewRequest) -> dict:
        # First authorization rejects stale sessions before even calculating a
        # plan; the second check binds the committed preview to fresh authority.
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
        entry = next((entry for entry in self._catalog.entries if
                      entry.manifest.serviceId == body.serviceId and
                      entry.manifest.distributionId == body.distributionId), None)
        if entry is None:
            raise ApiError("not_found", 404)
        if entry.manifestDigest != body.manifestDigest:
            raise ApiError("plugin_catalog_changed", 409)
        try:
            calculated = plan(entry, body.settings, body.platform)
        except ValueError:
            raise ApiError("invalid_request") from None
        with self.db.transaction() as connection:
            actor_revision = self._assert_admin(connection, actor)
            now = int(self.settings.clock())
            connection.execute("DELETE FROM plugin_previews WHERE expires_at<=?", (now,))
            if connection.execute("SELECT COUNT(*) FROM plugin_previews").fetchone()[0] >= MAX_PREVIEWS:
                raise ApiError("plugin_preview_limit_reached", 409)
            row = {"id": uuid.uuid4().hex, "revision": 1, "actor_id": actor.id,
                   "actor_revision": actor_revision, "family_id": actor.family_id,
                   "created_at": now, "expires_at": now + PREVIEW_TTL}
            nonce = secrets.token_bytes(12)
            ciphertext = self._cipher.encrypt(nonce, calculated.model_dump_json().encode("utf-8"), self._aad(row))
            connection.execute("INSERT INTO plugin_previews VALUES(?,?,?,?,?,?,?,?,?)",
                               (*row.values(), nonce, ciphertext))
        return self._public(row, calculated)

    def get_preview(self, actor: Principal, preview_id: str) -> dict:
        if not isinstance(preview_id, str) or not re.fullmatch(r"[0-9a-f]{32}", preview_id):
            raise ApiError("invalid_request")
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            revision = self._assert_admin(connection, actor)
            row = connection.execute("SELECT * FROM plugin_previews WHERE id=?", (preview_id,)).fetchone()
            if row is None:
                raise ApiError("not_found", 404)
            calculated = self._decode(row)
            if row["actor_id"] != actor.id or row["family_id"] != actor.family_id:
                raise ApiError("not_found", 404)
            if row["expires_at"] <= self.settings.clock():
                raise ApiError("plugin_preview_expired", 409)
            if row["actor_revision"] != revision or calculated.catalogDigest != self._catalog.digest:
                raise ApiError("plugin_catalog_changed", 409)
            return self._public(row, calculated)
