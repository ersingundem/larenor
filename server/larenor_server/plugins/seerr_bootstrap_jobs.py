"""Encrypted durable Seerr bootstrap intent over one verified Jellyfin source."""

import json
import re
import secrets
import sqlite3
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import ValidationError

from ..admin.service import utc
from ..errors import ApiError, StartupError
from .seerr_bootstrap_job_models import (
    CreateSeerrBootstrapRequest,
    SeerrBootstrapJob,
)
from .seerr_bootstrap_models import PrivateSeerrBootstrap


MAX_BOOTSTRAPS = 256
MAX_CIPHERTEXT = 2048
_BINDING = (
    "id",
    "sequence",
    "revision",
    "actor_id",
    "actor_revision",
    "family_id",
    "request_id",
    "installation_id",
    "installation_revision",
    "source_bootstrap_id",
    "source_bootstrap_revision",
    "state",
    "phase",
    "error_code",
    "created_at",
    "updated_at",
)


def _identifier(value):
    if type(value) is not str or re.fullmatch(r"[0-9a-f]{32}", value) is None:
        raise ApiError("invalid_request")


def _request(value):
    try:
        if isinstance(value, CreateSeerrBootstrapRequest):
            value = value.model_dump(mode="python")
        return CreateSeerrBootstrapRequest.model_validate(value)
    except (ValidationError, ValueError, TypeError, AttributeError):
        raise ApiError("invalid_request") from None


class SeerrBootstrapManagement:
    def __init__(self, db, auth, settings, key, installations, jellyfin_bootstraps):
        self.db, self.auth, self.settings = db, auth, settings
        self.installations = installations
        self.jellyfin_bootstraps = jellyfin_bootstraps
        self._cipher = AESGCM(key)

    def _assert_admin(self, connection, actor):
        return self.installations._assert_admin(connection, actor)

    @staticmethod
    def _aad(row):
        return b"larenor:media:seerr-bootstraps:schema=1:" + json.dumps(
            {key: row[key] for key in _BINDING},
            sort_keys=True,
            separators=(",", ":"),
        ).encode("ascii")

    @staticmethod
    def _public(row):
        try:
            return SeerrBootstrapJob.model_validate(
                {
                    "id": row["id"],
                    "requestId": row["request_id"],
                    "installationId": row["installation_id"],
                    "sourceBootstrapId": row["source_bootstrap_id"],
                    "sourceBootstrapRevision": row["source_bootstrap_revision"],
                    "serviceId": "seerr",
                    "revision": row["revision"],
                    "state": row["state"],
                    "phase": row["phase"],
                    "errorCode": row["error_code"],
                    "installAvailable": False,
                    "createdAt": utc(row["created_at"]),
                    "updatedAt": utc(row["updated_at"]),
                }
            ).model_dump()
        except (ValidationError, ValueError, TypeError, AttributeError):
            raise ApiError("seerr_bootstrap_storage_unavailable", 503) from None

    def _decode(self, row):
        try:
            if (
                len(row["nonce"]) != 12
                or not 16 <= len(row["ciphertext"]) <= MAX_CIPHERTEXT
                or any(
                    type(row[key]) is not int or not 1 <= row[key] <= 2**63 - 2
                    for key in (
                        "sequence",
                        "revision",
                        "actor_revision",
                        "installation_revision",
                        "source_bootstrap_revision",
                    )
                )
                or any(
                    type(row[key]) is not str
                    or re.fullmatch(r"[0-9a-f]{32}", row[key]) is None
                    for key in (
                        "id",
                        "actor_id",
                        "family_id",
                        "request_id",
                        "installation_id",
                        "source_bootstrap_id",
                    )
                )
            ):
                raise ValueError()
            private = PrivateSeerrBootstrap.model_validate_json(
                self._cipher.decrypt(row["nonce"], row["ciphertext"], self._aad(row))
            )
            if (
                private.sourceBootstrapId != row["source_bootstrap_id"]
                or private.sourceBootstrapRevision != row["source_bootstrap_revision"]
            ):
                raise ValueError()
            self._public(row)
            return private
        except (
            InvalidTag,
            ValidationError,
            ValueError,
            TypeError,
            AttributeError,
            KeyError,
            OverflowError,
        ):
            raise ApiError("seerr_bootstrap_storage_unavailable", 503) from None

    def _validate_row(self, connection, row):
        private = self._decode(row)
        installation = connection.execute(
            "SELECT * FROM media_installations WHERE id=?", (row["installation_id"],)
        ).fetchone()
        source = connection.execute(
            "SELECT * FROM media_service_bootstraps WHERE id=?",
            (row["source_bootstrap_id"],),
        ).fetchone()
        try:
            if installation is None or source is None:
                raise ValueError()
            installed = self.installations._decode(installation)
            source_private = self.jellyfin_bootstraps._decode(source)
            source_installation = connection.execute(
                "SELECT * FROM media_installations WHERE id=?",
                (source["installation_id"],),
            ).fetchone()
            if (
                source_installation is None
                or installation["revision"] != row["installation_revision"]
                or installation["state"] != "container_started"
                or installation["phase"] != "complete"
                or installed.request.serviceId != "seerr"
                or source["revision"] != row["source_bootstrap_revision"]
                or source["state"] not in {"wiring_partial", "succeeded"}
                or source["credentials_configured"] != 1
                or source_private.readback is None
                or source_installation["preparation_id"] != installation["preparation_id"]
                or any(
                    item != row[column]
                    for item, column in (
                        (installation["actor_id"], "actor_id"),
                        (installation["actor_revision"], "actor_revision"),
                        (installation["family_id"], "family_id"),
                        (source["actor_id"], "actor_id"),
                        (source["actor_revision"], "actor_revision"),
                        (source["family_id"], "family_id"),
                    )
                )
            ):
                raise ValueError()
            return private
        except (ApiError, ValidationError, ValueError, TypeError, AttributeError):
            raise ApiError("seerr_bootstrap_storage_unavailable", 503) from None

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                connection.execute("BEGIN")
                rows = connection.execute(
                    "SELECT * FROM media_seerr_bootstraps LIMIT ?", (MAX_BOOTSTRAPS + 1,)
                ).fetchall()
                if len(rows) > MAX_BOOTSTRAPS:
                    raise ValueError()
                for row in rows:
                    self._validate_row(connection, row)
        except (ApiError, ValueError, sqlite3.Error):
            raise StartupError("invalid_media_seerr_bootstraps_storage") from None

    def create(self, actor, body):
        body = _request(body)
        with self.db.transaction() as connection:
            actor_revision = self._assert_admin(connection, actor)
            previous = connection.execute(
                "SELECT * FROM media_seerr_bootstraps WHERE actor_id=? AND request_id=?",
                (actor.id, body.requestId),
            ).fetchone()
            if previous is not None:
                if (
                    previous["installation_id"] != body.installationId
                    or previous["installation_revision"]
                    != body.expectedInstallationRevision
                    or previous["source_bootstrap_id"] != body.sourceBootstrapId
                    or previous["source_bootstrap_revision"]
                    != body.expectedSourceBootstrapRevision
                ):
                    raise ApiError("seerr_bootstrap_conflict", 409)
                self._validate_row(connection, previous)
                return {"bootstrap": self._public(previous)}
            installation = connection.execute(
                "SELECT * FROM media_installations WHERE id=?", (body.installationId,)
            ).fetchone()
            source = connection.execute(
                "SELECT * FROM media_service_bootstraps WHERE id=?",
                (body.sourceBootstrapId,),
            ).fetchone()
            if installation is None:
                raise ApiError("seerr_installation_changed", 409)
            if source is None or source["revision"] != body.expectedSourceBootstrapRevision:
                raise ApiError("seerr_bootstrap_source_changed", 409)
            try:
                installed = self.installations._decode(installation)
                source_private = self.jellyfin_bootstraps._decode(source)
                source_installation = connection.execute(
                    "SELECT * FROM media_installations WHERE id=?",
                    (source["installation_id"],),
                ).fetchone()
                if (
                    installation["revision"] != body.expectedInstallationRevision
                    or installation["state"] != "container_started"
                    or installation["phase"] != "complete"
                    or installed.request.serviceId != "seerr"
                    or source_installation is None
                    or source_installation["preparation_id"]
                    != installation["preparation_id"]
                    or source["state"] not in {"wiring_partial", "succeeded"}
                    or source["credentials_configured"] != 1
                    or source_private.readback is None
                    or any(
                        value != expected
                        for value, expected in (
                            (installation["actor_id"], actor.id),
                            (installation["actor_revision"], actor_revision),
                            (installation["family_id"], actor.family_id),
                            (source["actor_id"], actor.id),
                            (source["actor_revision"], actor_revision),
                            (source["family_id"], actor.family_id),
                        )
                    )
                ):
                    raise ValueError()
            except (ApiError, ValidationError, ValueError, TypeError, AttributeError):
                code = (
                    "seerr_installation_changed"
                    if installed.request.serviceId != "seerr"
                    else "seerr_bootstrap_source_changed"
                ) if "installed" in locals() else "seerr_installation_changed"
                raise ApiError(code, 409) from None
            if connection.execute(
                "SELECT 1 FROM media_seerr_bootstraps WHERE installation_id=?",
                (body.installationId,),
            ).fetchone() is not None:
                raise ApiError("seerr_bootstrap_conflict", 409)
            if connection.execute(
                "SELECT COUNT(*) FROM media_seerr_bootstraps"
            ).fetchone()[0] >= MAX_BOOTSTRAPS:
                raise ApiError("seerr_bootstrap_limit_reached", 409)
            now = int(self.settings.clock())
            row = {
                "id": uuid.uuid4().hex,
                "sequence": connection.execute(
                    "SELECT COALESCE(MAX(sequence),0)+1 FROM media_seerr_bootstraps"
                ).fetchone()[0],
                "revision": 1,
                "actor_id": actor.id,
                "actor_revision": actor_revision,
                "family_id": actor.family_id,
                "request_id": body.requestId,
                "installation_id": body.installationId,
                "installation_revision": body.expectedInstallationRevision,
                "source_bootstrap_id": body.sourceBootstrapId,
                "source_bootstrap_revision": body.expectedSourceBootstrapRevision,
                "state": "queued",
                "phase": "queued",
                "error_code": None,
                "created_at": now,
                "updated_at": now,
            }
            private = PrivateSeerrBootstrap(
                credential=secrets.token_urlsafe(48),
                sourceBootstrapId=body.sourceBootstrapId,
                sourceBootstrapRevision=body.expectedSourceBootstrapRevision,
            )
            nonce = secrets.token_bytes(12)
            ciphertext = self._cipher.encrypt(
                nonce, private.model_dump_json().encode("utf-8"), self._aad(row)
            )
            if len(ciphertext) > MAX_CIPHERTEXT:
                raise ApiError("seerr_bootstrap_storage_unavailable", 503)
            connection.execute(
                "INSERT INTO media_seerr_bootstraps("
                + ",".join(_BINDING)
                + ",nonce,ciphertext) VALUES("
                + ",".join("?" for _ in range(len(_BINDING) + 2))
                + ")",
                (*[row[key] for key in _BINDING], nonce, ciphertext),
            )
            stored = connection.execute(
                "SELECT * FROM media_seerr_bootstraps WHERE id=?", (row["id"],)
            ).fetchone()
            self._validate_row(connection, stored)
            return {"bootstrap": self._public(stored)}

    def _find(self, connection, identifier):
        row = connection.execute(
            "SELECT * FROM media_seerr_bootstraps WHERE id=?", (identifier,)
        ).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        self._validate_row(connection, row)
        return row

    def get(self, actor, identifier):
        _identifier(identifier)
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            return {"bootstrap": self._public(self._find(connection, identifier))}

    def list(self, actor, *, before=None, limit=10):
        if (
            type(limit) is not int
            or not 1 <= limit <= 10
            or before is not None
            and (type(before) is not int or not 1 <= before <= 2**63 - 1)
        ):
            raise ApiError("invalid_request")
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self._assert_admin(connection, actor)
            rows = connection.execute(
                "SELECT * FROM media_seerr_bootstraps WHERE sequence<? "
                "ORDER BY sequence DESC LIMIT ?",
                (before or 2**63 - 1, limit + 1),
            ).fetchall()
            for row in rows:
                self._validate_row(connection, row)
            return {
                "bootstraps": [self._public(row) for row in rows[:limit]],
                "nextBefore": rows[limit - 1]["sequence"] if len(rows) > limit else None,
            }

    def private_payload(self, identifier):
        _identifier(identifier)
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            return self._decode(self._find(connection, identifier))

