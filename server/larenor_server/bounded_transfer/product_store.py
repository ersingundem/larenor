"""Encrypted product blobs bound to one authorized Home resource."""

import hashlib
import hmac
import json
import math
import re
import secrets
import sqlite3

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from . import blob_schema
from .media_policy import validate_media_payload
from .models import BlobDescriptor


_IDENTITY = re.compile(r"^[0-9a-f]{32}$")
_DIGEST = re.compile(r"^[0-9a-f]{64}$")
_CONTENT_TYPE = re.compile(r"^[A-Za-z0-9!#$&^_.+\-/;= ]{1,128}$")


def _json(value) -> bytes:
    return json.dumps(
        value, ensure_ascii=True, separators=(",", ":"), allow_nan=False
    ).encode("ascii")


class ProductBlobStore:
    """One replaceable encrypted object per resource plus immutable upload receipts."""

    def __init__(self, db, settings, key, registry):
        self.db = db
        self.clock = settings.clock
        self.key = key
        self.registry = registry
        self._cipher = AESGCM(key)

    @staticmethod
    def envelope_hash(actor_id, core_id, home_id, resource_id, values):
        return hashlib.sha256(
            _json([actor_id, core_id, home_id, resource_id, values])
        ).hexdigest()

    def _object_aad(self, row):
        return b"larenor-bounded-product-blob-v1\0" + _json(
            [
                row[key]
                for key in (
                    "resource_id",
                    "core_id",
                    "home_id",
                    "request_id",
                    "service_revision",
                    "content_length",
                    "sha256",
                    "content_type",
                    "created_at",
                    "updated_at",
                )
            ]
        )

    def _object_tag(self, row):
        return hmac.new(
            self.key,
            b"larenor-bounded-product-object-v1\0"
            + self._object_aad(row)
            + hashlib.sha256(row["nonce"] + row["ciphertext"]).digest(),
            hashlib.sha256,
        ).hexdigest()

    def _upload_tag(self, row):
        return hmac.new(
            self.key,
            b"larenor-bounded-product-upload-v1\0"
            + _json(
                [
                    row[key]
                    for key in (
                        "request_id",
                        "actor_id",
                        "core_id",
                        "home_id",
                        "resource_id",
                        "envelope_hash",
                        "service_revision",
                        "content_length",
                        "sha256",
                        "content_type",
                        "created_at",
                        "updated_at",
                    )
                ]
            ),
            hashlib.sha256,
        ).hexdigest()

    @staticmethod
    def _valid_public(row, *, actor=False, envelope=False):
        identities = [row[key] for key in ("request_id", "core_id", "home_id", "resource_id")]
        if actor:
            identities.append(row["actor_id"])
        return (
            all(type(value) is str and _IDENTITY.fullmatch(value) for value in identities)
            and (not envelope or type(row["envelope_hash"]) is str and _DIGEST.fullmatch(row["envelope_hash"]))
            and type(row["service_revision"]) is int
            and 1 <= row["service_revision"] <= 2**63 - 1
            and type(row["content_length"]) is int
            and 1 <= row["content_length"] <= 256 * 1024
            and type(row["sha256"]) is str
            and _DIGEST.fullmatch(row["sha256"])
            and type(row["content_type"]) is str
            and _CONTENT_TYPE.fullmatch(row["content_type"])
            and "\r" not in row["content_type"]
            and "\n" not in row["content_type"]
            and type(row["created_at"]) is float
            and type(row["updated_at"]) is float
            and math.isfinite(row["created_at"])
            and math.isfinite(row["updated_at"])
            and 0 <= row["created_at"] <= row["updated_at"]
            and type(row["authentication_tag"]) is str
            and _DIGEST.fullmatch(row["authentication_tag"])
        )

    def _decode_object(self, row):
        if (
            not self._valid_public(row)
            or type(row["nonce"]) is not bytes
            or len(row["nonce"]) != 12
            or type(row["ciphertext"]) is not bytes
            or not 17 <= len(row["ciphertext"]) <= 256 * 1024 + 16
            or not hmac.compare_digest(row["authentication_tag"], self._object_tag(row))
        ):
            raise ValueError("invalid_object")
        content = self._cipher.decrypt(
            row["nonce"], row["ciphertext"], self._object_aad(row)
        )
        if (
            len(content) != row["content_length"]
            or not hmac.compare_digest(hashlib.sha256(content).hexdigest(), row["sha256"])
        ):
            raise ValueError("invalid_object")
        return content

    def _verify_upload(self, row):
        if (
            not self._valid_public(row, actor=True, envelope=True)
            or not hmac.compare_digest(row["authentication_tag"], self._upload_tag(row))
        ):
            raise ValueError("invalid_upload")

    @staticmethod
    def _public(row, *, request=True):
        result = {
            "resourceId": row["resource_id"],
            "serviceRevision": row["service_revision"],
            "contentLength": row["content_length"],
            "sha256": row["sha256"],
            "contentType": row["content_type"],
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
        }
        if request:
            result = {"requestId": row["request_id"], **result}
        return {"blob": result}

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                objects = connection.execute(
                    "SELECT * FROM bounded_blob_objects ORDER BY resource_id LIMIT ?",
                    (blob_schema.MAX_OBJECTS + 1,),
                ).fetchall()
                uploads = connection.execute(
                    "SELECT * FROM bounded_blob_uploads ORDER BY created_at,request_id LIMIT ?",
                    (blob_schema.MAX_UPLOADS + 1,),
                ).fetchall()
                if len(objects) > blob_schema.MAX_OBJECTS or len(uploads) > blob_schema.MAX_UPLOADS:
                    raise ValueError("storage_limit")
                known = {}
                for row in objects:
                    self._decode_object(row)
                    known[row["resource_id"]] = row
                for row in uploads:
                    self._verify_upload(row)
                for row in known.values():
                    receipt = next(
                        (
                            item
                            for item in uploads
                            if item["request_id"] == row["request_id"]
                        ),
                        None,
                    )
                    if receipt is None or any(
                        receipt[key] != row[key]
                        for key in (
                            "core_id",
                            "home_id",
                            "resource_id",
                            "service_revision",
                            "content_length",
                            "sha256",
                            "content_type",
                            "created_at",
                            "updated_at",
                        )
                    ):
                        raise ValueError("object_upload_mismatch")
        except (InvalidTag, sqlite3.Error, ValueError, TypeError, OverflowError):
            raise StartupError("bounded_blob_storage_invalid") from None

    def resolve(self, resource_id: str) -> BlobDescriptor | None:
        try:
            with self.db.connection() as connection:
                row = connection.execute(
                    "SELECT * FROM bounded_blob_objects WHERE resource_id=?",
                    (resource_id,),
                ).fetchone()
                if row is None:
                    return None
                content = self._decode_object(row)
                return BlobDescriptor(
                    resource_id=row["resource_id"],
                    service_revision=row["service_revision"],
                    content_type=row["content_type"],
                    content=content,
                )
        except (InvalidTag, sqlite3.Error, ValueError, TypeError, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def validate_reference(self, connection, core_id, home_id, resource_id, *, missing):
        """Verify the encrypted object and its immutable upload receipt in-place."""
        if missing not in {"invalid_request", "not_found"}:
            raise ApiError("invalid_request")
        row = connection.execute(
            "SELECT * FROM bounded_blob_objects WHERE resource_id=?", (resource_id,)
        ).fetchone()
        if row is None:
            raise ApiError(missing, 404 if missing == "not_found" else 400)
        self._decode_object(row)
        receipt = connection.execute(
            "SELECT * FROM bounded_blob_uploads WHERE request_id=?", (row["request_id"],)
        ).fetchone()
        if receipt is None:
            raise ValueError("missing_object_upload")
        self._verify_upload(receipt)
        if (row["core_id"], row["home_id"]) != (core_id, home_id) or any(
            receipt[key] != row[key] for key in (
                "core_id", "home_id", "resource_id", "service_revision",
                "content_length", "sha256", "content_type", "created_at", "updated_at",
            )
        ):
            raise ValueError("object_upload_mismatch")

    def replay(self, actor, core_id, home_id, resource_id, request_id, envelope):
        try:
            with self.db.connection() as connection:
                row = connection.execute(
                    "SELECT * FROM bounded_blob_uploads WHERE request_id=?",
                    (request_id,),
                ).fetchone()
                if row is None:
                    return None
                self._verify_upload(row)
                exact = (
                    row["actor_id"] == actor.id
                    and row["core_id"] == core_id
                    and row["home_id"] == home_id
                    and row["resource_id"] == resource_id
                    and hmac.compare_digest(row["envelope_hash"], envelope)
                )
                if not exact:
                    raise ApiError("idempotency_conflict", 409)
                return self._public(row)
        except ApiError:
            raise
        except (sqlite3.Error, ValueError, TypeError, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def descriptor(self, actor, core_id, home_id, resource_id):
        self.registry.get(actor, core_id, home_id, resource_id)
        try:
            with self.db.connection() as connection:
                row = connection.execute(
                    "SELECT * FROM bounded_blob_objects WHERE resource_id=?",
                    (resource_id,),
                ).fetchone()
                if row is None:
                    raise ApiError("not_found", 404)
                self._decode_object(row)
                return self._public(row, request=False)
        except ApiError:
            raise
        except (InvalidTag, sqlite3.Error, ValueError, TypeError, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def put(self, actor, core_id, home_id, resource_id, request_id, values, content):
        validate_media_payload(values["contentType"], content)
        envelope = self.envelope_hash(actor.id, core_id, home_id, resource_id, values)
        replay = self.replay(
            actor, core_id, home_id, resource_id, request_id, envelope
        )
        if replay is not None:
            return replay, False

        def commit(connection, _facts):
            old_upload = connection.execute(
                "SELECT * FROM bounded_blob_uploads WHERE request_id=?",
                (request_id,),
            ).fetchone()
            if old_upload is not None:
                self._verify_upload(old_upload)
                exact = (
                    old_upload["actor_id"] == actor.id
                    and old_upload["resource_id"] == resource_id
                    and hmac.compare_digest(old_upload["envelope_hash"], envelope)
                )
                if not exact:
                    raise ApiError("idempotency_conflict", 409)
                return self._public(old_upload), False
            old = connection.execute(
                "SELECT * FROM bounded_blob_objects WHERE resource_id=?",
                (resource_id,),
            ).fetchone()
            expected = values["expectedServiceRevision"]
            observed_now = self.clock()
            if old is None:
                if expected != 0:
                    raise ApiError("revision_conflict", 409)
                count = connection.execute(
                    "SELECT COUNT(*) FROM bounded_blob_objects"
                ).fetchone()[0]
                if count >= blob_schema.MAX_OBJECTS:
                    raise ApiError("bounded_transfer_limit_reached", 429)
                revision = 1
                created = observed_now
                now = observed_now
            else:
                self._decode_object(old)
                if old["service_revision"] != expected or expected >= 2**63 - 1:
                    raise ApiError("revision_conflict", 409)
                revision = expected + 1
                created = old["created_at"]
                now = max(observed_now, old["updated_at"])
            if connection.execute(
                "SELECT COUNT(*) FROM bounded_blob_uploads"
            ).fetchone()[0] >= blob_schema.MAX_UPLOADS:
                raise ApiError("bounded_transfer_limit_reached", 429)
            row = {
                "resource_id": resource_id,
                "core_id": core_id,
                "home_id": home_id,
                "request_id": request_id,
                "service_revision": revision,
                "content_length": values["contentLength"],
                "sha256": values["sha256"],
                "content_type": values["contentType"],
                "created_at": created,
                "updated_at": now,
            }
            row["nonce"] = secrets.token_bytes(12)
            row["ciphertext"] = self._cipher.encrypt(
                row["nonce"], content, self._object_aad(row)
            )
            row["authentication_tag"] = self._object_tag(row)
            connection.execute(
                "INSERT INTO bounded_blob_objects VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) "
                "ON CONFLICT(resource_id) DO UPDATE SET "
                "core_id=excluded.core_id,home_id=excluded.home_id,request_id=excluded.request_id," 
                "service_revision=excluded.service_revision,content_length=excluded.content_length," 
                "sha256=excluded.sha256,content_type=excluded.content_type," 
                "created_at=excluded.created_at,updated_at=excluded.updated_at," 
                "nonce=excluded.nonce,ciphertext=excluded.ciphertext," 
                "authentication_tag=excluded.authentication_tag",
                tuple(row.values()),
            )
            upload = {
                "request_id": request_id,
                "actor_id": actor.id,
                "core_id": core_id,
                "home_id": home_id,
                "resource_id": resource_id,
                "envelope_hash": envelope,
                "service_revision": revision,
                "content_length": values["contentLength"],
                "sha256": values["sha256"],
                "content_type": values["contentType"],
                "created_at": created,
                "updated_at": now,
            }
            upload["authentication_tag"] = self._upload_tag(upload)
            connection.execute(
                "INSERT INTO bounded_blob_uploads VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                tuple(upload.values()),
            )
            return self._public(upload), old is None

        return self.registry.perform_authorized(
            actor,
            core_id,
            home_id,
            resource_id,
            "write",
            commit,
            expected_user_revision=values["expectedUserRevision"],
            expected_revision=values["expectedRevision"],
            expected_acl_revision=values["expectedAclRevision"],
        )


class CompositeBlobProvider:
    def __init__(self, packaged, product):
        self.packaged = packaged
        self.product = product

    def resolve(self, resource_id):
        if self.packaged is not None:
            value = self.packaged.resolve(resource_id)
            if value is not None:
                return value
        return self.product.resolve(resource_id)
