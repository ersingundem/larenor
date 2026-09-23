import hashlib
import hmac
import json
import re
import secrets
import sqlite3

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from . import schema
from .models import (
    MediaLanguagePreferenceResponse,
    PutMediaLanguagePreference,
    StoredMediaLanguagePreference,
)


class MediaLanguagePreferenceService:
    """Encrypted account preferences with CAS and exact replay receipts."""

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings = db, auth, settings
        self.scope = HomeScope.model_validate(context.model_dump())
        self._key, self._cipher = key, AESGCM(key)

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    @staticmethod
    def _identity(value):
        if type(value) is not str or re.fullmatch(r"[0-9a-f]{32}", value) is None:
            raise ValueError("invalid_identity")

    @staticmethod
    def _revision(value, *, empty=False):
        minimum = 0 if empty else 1
        if type(value) is not int or not minimum <= value <= 2**63 - 1:
            raise ValueError("invalid_revision")

    def _record_aad(self, owner_id, revision):
        return (
            f"larenor-media-language-preference-v1:{self.scope.coreId}:"
            f"{self.scope.homeId}:{owner_id}:{revision}"
        ).encode("ascii")

    def _receipt_aad(self, owner_id, family_id, request_id, request_hash):
        return (
            f"larenor-media-language-preference-receipt-v1:{self.scope.coreId}:"
            f"{self.scope.homeId}:{owner_id}:{family_id}:{request_id}:{request_hash}"
        ).encode("ascii")

    def _decode(self, row):
        self._identity(row["owner_id"])
        self._revision(row["revision"])
        if (
            type(row["nonce"]) is not bytes
            or len(row["nonce"]) != 12
            or type(row["ciphertext"]) is not bytes
            or not 16 <= len(row["ciphertext"]) <= 1024
        ):
            raise ValueError("invalid_record")
        return StoredMediaLanguagePreference.model_validate_json(
            self._cipher.decrypt(
                row["nonce"],
                row["ciphertext"],
                self._record_aad(row["owner_id"], row["revision"]),
            )
        )

    def _actor(self, connection, actor, *, expected=None):
        self.auth.assert_current(connection, actor)
        row = connection.execute(
            "SELECT id,revision,disabled,must_change_password FROM users WHERE id=?",
            (actor.id,),
        ).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("invalid_session", 401)
        if expected is not None and row["revision"] != expected:
            raise ApiError("revision_conflict", 409)
        return row

    def _authority(self, actor, account, revision):
        return {
            **self.scope.model_dump(),
            "accountId": actor.id,
            "sessionFamilyId": actor.family_id,
            "accountRevision": account["revision"],
            "preferenceRevision": revision,
        }

    def _public(self, actor, account, row, preference):
        revision = 0 if row is None else row["revision"]
        public = None
        if preference is not None:
            public = {
                "schemaVersion": 1,
                "ref": {
                    **self.scope.model_dump(),
                    "accountId": actor.id,
                    "kind": "media_language_preferences",
                },
                "revision": revision,
                **preference.model_dump(),
            }
        return {
            "schemaVersion": 1,
            "authority": self._authority(actor, account, revision),
            "preference": public,
        }

    def _request_hash(self, body):
        encoded = json.dumps(
            body.model_dump(mode="json"),
            sort_keys=True,
            separators=(",", ":"),
        ).encode("ascii")
        return hmac.new(
            self._key,
            b"larenor-media-language-preference-request-v1\0" + encoded,
            hashlib.sha256,
        ).hexdigest()

    def _receipt(self, connection, actor, request_id, request_hash):
        row = connection.execute(
            "SELECT * FROM media_language_preference_receipts "
            "WHERE owner_id=? AND family_id=? AND request_id=?",
            (actor.id, actor.family_id, request_id),
        ).fetchone()
        if row is None:
            return None
        if not hmac.compare_digest(row["request_hash"], request_hash):
            raise ApiError("idempotency_conflict", 409)
        return self._decode_receipt(row)

    def _decode_receipt(self, row):
        if (
            type(row["nonce"]) is not bytes
            or len(row["nonce"]) != 12
            or type(row["ciphertext"]) is not bytes
            or not 16 <= len(row["ciphertext"]) <= 4096
        ):
            raise ValueError("invalid_receipt")
        return MediaLanguagePreferenceResponse.model_validate_json(
            self._cipher.decrypt(
                row["nonce"],
                row["ciphertext"],
                self._receipt_aad(
                    row["owner_id"],
                    row["family_id"],
                    row["request_id"],
                    row["request_hash"],
                ),
            )
        )

    def _save_receipt(self, connection, actor, body, request_hash, result):
        response = MediaLanguagePreferenceResponse.model_validate(result)
        plain = response.model_dump_json().encode("utf-8")
        if len(plain) > 4080:
            raise ApiError("invalid_request")
        nonce = secrets.token_bytes(12)
        connection.execute(
            "INSERT INTO media_language_preference_receipts("
            "owner_id,family_id,request_id,request_hash,nonce,ciphertext) "
            "VALUES(?,?,?,?,?,?)",
            (
                actor.id,
                actor.family_id,
                body.requestId,
                request_hash,
                nonce,
                self._cipher.encrypt(
                    nonce,
                    plain,
                    self._receipt_aad(
                        actor.id, actor.family_id, body.requestId, request_hash
                    ),
                ),
            ),
        )
        connection.execute(
            "DELETE FROM media_language_preference_receipts WHERE sequence IN ("
            "SELECT sequence FROM media_language_preference_receipts "
            "WHERE owner_id=? ORDER BY sequence DESC LIMIT -1 OFFSET ?)",
            (actor.id, schema.MAX_RECEIPTS_PER_ACCOUNT),
        )
        connection.execute(
            "DELETE FROM media_language_preference_receipts WHERE sequence IN ("
            "SELECT sequence FROM media_language_preference_receipts "
            "ORDER BY sequence DESC LIMIT -1 OFFSET ?)",
            (schema.MAX_RECEIPTS,),
        )

    def read(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        self.auth.rate_limit([("media_language_preference_read", actor.id, 240)])
        try:
            with self.db.transaction() as connection:
                account = self._actor(connection, actor)
                row = connection.execute(
                    "SELECT * FROM media_language_preferences WHERE owner_id=?",
                    (actor.id,),
                ).fetchone()
                preference = None if row is None else self._decode(row)
                return self._public(actor, account, row, preference)
        except ApiError:
            raise
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def put(self, actor, core_id, home_id, value):
        body = PutMediaLanguagePreference.model_validate(value)
        self._scope(core_id, home_id)
        self.auth.rate_limit([("media_language_preference_write", actor.id, 120)])
        request_hash = self._request_hash(body)
        try:
            with self.db.transaction() as connection:
                account = self._actor(
                    connection, actor, expected=body.expectedAccountRevision
                )
                replay = self._receipt(
                    connection, actor, body.requestId, request_hash
                )
                current = connection.execute(
                    "SELECT * FROM media_language_preferences WHERE owner_id=?",
                    (actor.id,),
                ).fetchone()
                revision = 0 if current is None else current["revision"]
                if replay is not None:
                    if replay.authority.model_dump() != self._authority(
                        actor, account, revision
                    ):
                        raise ApiError("operation_replay", 409)
                    return replay.model_dump()
                if current is None and connection.execute(
                    "SELECT COUNT(*) FROM media_language_preferences"
                ).fetchone()[0] >= schema.MAX_RECORDS:
                    raise ApiError("media_language_preference_limit_reached", 409)
                if revision != body.expectedRevision or revision >= 2**63 - 1:
                    raise ApiError("revision_conflict", 409)
                if current is not None:
                    self._decode(current)
                preference = StoredMediaLanguagePreference(
                    audioLanguage=body.audioLanguage,
                    subtitleLanguage=body.subtitleLanguage,
                )
                next_revision = revision + 1
                plain = preference.model_dump_json().encode("utf-8")
                if len(plain) > 1008:
                    raise ApiError("invalid_request")
                nonce = secrets.token_bytes(12)
                ciphertext = self._cipher.encrypt(
                    nonce,
                    plain,
                    self._record_aad(actor.id, next_revision),
                )
                connection.execute(
                    "INSERT INTO media_language_preferences VALUES(?,?,?,?) "
                    "ON CONFLICT(owner_id) DO UPDATE SET "
                    "revision=excluded.revision,nonce=excluded.nonce,"
                    "ciphertext=excluded.ciphertext",
                    (actor.id, next_revision, nonce, ciphertext),
                )
                row = {"owner_id": actor.id, "revision": next_revision}
                result = self._public(actor, account, row, preference)
                self._save_receipt(connection, actor, body, request_hash, result)
                return result
        except ApiError:
            raise
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                records = connection.execute(
                    "SELECT * FROM media_language_preferences LIMIT ?",
                    (schema.MAX_RECORDS + 1,),
                ).fetchall()
                if len(records) > schema.MAX_RECORDS:
                    raise ValueError("too_many_records")
                for row in records:
                    self._decode(row)
                receipts = connection.execute(
                    "SELECT * FROM media_language_preference_receipts LIMIT ?",
                    (schema.MAX_RECEIPTS + 1,),
                ).fetchall()
                if len(receipts) > schema.MAX_RECEIPTS:
                    raise ValueError("too_many_receipts")
                per_owner = {}
                for row in receipts:
                    self._identity(row["owner_id"])
                    self._identity(row["family_id"])
                    self._identity(row["request_id"])
                    if re.fullmatch(r"[0-9a-f]{64}", row["request_hash"] or "") is None:
                        raise ValueError("invalid_receipt")
                    self._decode_receipt(row)
                    per_owner[row["owner_id"]] = per_owner.get(row["owner_id"], 0) + 1
                    if per_owner[row["owner_id"]] > schema.MAX_RECEIPTS_PER_ACCOUNT:
                        raise ValueError("too_many_account_receipts")
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise StartupError(
                "media_language_preference_storage_invalid"
            ) from None
