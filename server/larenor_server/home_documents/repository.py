import json
import re
import secrets
import sqlite3
import threading

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from .models import CreateHomeDocumentCommand, DocumentActor, DocumentBlobRef
from .service import HomeDocumentLibrary


MAX_STATE_BYTES = 16 * 1024 * 1024
_IDENTITY = re.compile(r"^[0-9a-f]{32}$")


class HomeDocumentRepository:
    """Durable encrypted owner for the bounded home-document reducer."""

    def __init__(self, db, auth, settings, key, context, product_blobs, inventory):
        self.db, self.auth, self.settings = db, auth, settings
        self.scope = HomeScope.model_validate(context.model_dump())
        self._cipher = AESGCM(key)
        self._lock = threading.RLock()
        self._product_blobs = product_blobs
        self._inventory = inventory
        self._blob_current = self._production_blob_current
        self._inventory_current = self._production_inventory_current
        self._library = self._empty()
        self.validate_storage()

    def _empty(self):
        return HomeDocumentLibrary(
            self.scope,
            blob_current=lambda _actor, _blob: True,
            inventory_current=lambda _actor, _item: True,
            clock=self.settings.clock,
        )

    def _aad(self, revision):
        return (
            f"larenor-home-documents-v1:{self.scope.coreId}:"
            f"{self.scope.homeId}:{revision}"
        ).encode("ascii")

    def _decode(self, row):
        if (
            row["singleton"] != 1
            or type(row["revision"]) is not int
            or not 0 <= row["revision"] <= 2**63 - 1
            or type(row["nonce"]) is not bytes
            or len(row["nonce"]) != 12
            or type(row["ciphertext"]) is not bytes
            or not 16 <= len(row["ciphertext"]) <= MAX_STATE_BYTES + 16
        ):
            raise ValueError("invalid_home_document_state")
        raw = self._cipher.decrypt(
            row["nonce"], row["ciphertext"], self._aad(row["revision"])
        )
        if len(raw) > MAX_STATE_BYTES:
            raise ValueError("home_document_state_too_large")
        value = json.loads(raw.decode("utf-8"))
        library = self._empty()
        library.restore_state(value)
        if library.revision != row["revision"]:
            raise ValueError("home_document_revision_mismatch")
        return library

    def _read(self, connection):
        rows = connection.execute(
            "SELECT * FROM home_document_state LIMIT 2"
        ).fetchall()
        if len(rows) > 1:
            raise ValueError("duplicate_home_document_state")
        return self._empty() if not rows else self._decode(rows[0])

    def _sync(self):
        with self.db.connection() as connection:
            self._library = self._read(connection)

    def _persist(self, previous_revision):
        value = self._library.snapshot_state()
        plain = json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        if len(plain) > MAX_STATE_BYTES:
            raise ApiError("revision_conflict", 409)
        revision = self._library.revision
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(nonce, plain, self._aad(revision))
        with self.db.transaction() as connection:
            row = connection.execute(
                "SELECT revision FROM home_document_state WHERE singleton=1"
            ).fetchone()
            current = 0 if row is None else row["revision"]
            if current != previous_revision:
                raise ApiError("revision_conflict", 409)
            connection.execute(
                "INSERT INTO home_document_state VALUES(1,?,?,?) "
                "ON CONFLICT(singleton) DO UPDATE SET "
                "revision=excluded.revision,nonce=excluded.nonce,"
                "ciphertext=excluded.ciphertext",
                (revision, nonce, ciphertext),
            )

    def _actor(self, principal):
        with self.db.connection() as connection:
            self.auth.assert_current(connection, principal)
            row = connection.execute(
                "SELECT revision,role,disabled,must_change_password "
                "FROM users WHERE id=?",
                (principal.id,),
            ).fetchone()
        if (
            row is None
            or row["disabled"]
            or row["must_change_password"]
            or principal.must_change_password
        ):
            raise ApiError("invalid_session", 401)
        return DocumentActor(
            schemaVersion=1,
            accountId=principal.id,
            accountRevision=row["revision"],
            sessionFamilyId=principal.family_id,
            role=row["role"],
        )

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    def _production_blob_current(self, principal, blob):
        value = self._product_blobs.descriptor(
            principal, self.scope.coreId, self.scope.homeId, blob.resourceId
        )["blob"]
        return all(
            value[key] == expected
            for key, expected in {
                "resourceId": blob.resourceId,
                "serviceRevision": blob.serviceRevision,
                "contentLength": blob.contentLength,
                "sha256": blob.sha256,
                "contentType": blob.contentType,
            }.items()
        )

    def _production_inventory_current(self, principal, item_id):
        item = self._inventory.get(
            principal, self.scope.coreId, self.scope.homeId, item_id
        )["item"]
        return item["ref"]["id"] == item_id

    def _references(self, principal, command):
        try:
            valid = self._blob_current(principal, command.blob) is True
            valid = (
                valid
                and self._inventory_current(principal, command.inventoryItemId) is True
            )
        except ApiError:
            raise
        except Exception:
            valid = False
        if not valid:
            raise ApiError("not_found", 404)

    def validate_storage(self):
        try:
            with self._lock:
                self._sync()
        except (
            InvalidTag,
            UnicodeError,
            json.JSONDecodeError,
            sqlite3.Error,
            ValueError,
            TypeError,
            OverflowError,
        ):
            raise StartupError("home_document_storage_invalid") from None

    def create(self, principal, core_id, home_id, value):
        command = CreateHomeDocumentCommand.model_validate(value)
        self._scope(core_id, home_id)
        self.auth.rate_limit([("home_document_write", principal.id, 60)])
        with self._lock:
            self._sync()
            actor = self._actor(principal)
            before = self._library.revision
            try:
                result = self._library.create(actor, command)
                if result.replayed:
                    return result
                self._references(principal, command)
                self._persist(before)
                return result
            except Exception:
                self._sync()
                raise

    def confirm_warranty(self, principal, core_id, home_id, value):
        self._scope(core_id, home_id)
        self.auth.rate_limit([("home_document_write", principal.id, 60)])
        with self._lock:
            self._sync()
            actor = self._actor(principal)
            before = self._library.revision
            try:
                result = self._library.confirm_warranty(actor, value)
                if not result.replayed:
                    self._persist(before)
                return result
            except Exception:
                self._sync()
                raise

    def search(self, principal, core_id, home_id, query, *, limit):
        self._scope(core_id, home_id)
        self.auth.rate_limit([("home_document_read", principal.id, 120)])
        with self._lock:
            self._sync()
            return self._library.search(self._actor(principal), query, limit=limit)

    def reminders(self, principal, core_id, home_id, today, *, limit):
        self._scope(core_id, home_id)
        self.auth.rate_limit([("home_document_read", principal.id, 120)])
        with self._lock:
            self._sync()
            return self._library.reminders(self._actor(principal), today, limit=limit)
