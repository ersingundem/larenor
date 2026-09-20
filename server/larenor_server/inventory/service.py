import re
import secrets
import sqlite3
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from . import schema
from .models import (
    CreateInventoryItem,
    InventoryItem,
    InventoryLinks,
    InventoryQr,
    InventoryRef,
    StoredInventoryItem,
)


class InventoryRegistry:
    def __init__(self, db, auth, key, context):
        self.db, self.auth = db, auth
        self.scope = HomeScope.model_validate(context.model_dump())
        self._cipher = AESGCM(key)

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    def _aad(self, item_id, revision, created_by):
        return (
            f"larenor-inventory-v1:{self.scope.coreId}:{self.scope.homeId}:"
            f"{item_id}:{revision}:{created_by}"
        ).encode("ascii")

    def _decode(self, row):
        if (
            not re.fullmatch(r"[0-9a-f]{32}", row["id"])
            or type(row["revision"]) is not int
            or not 1 <= row["revision"] <= 2**63 - 1
            or not re.fullmatch(r"[0-9a-f]{32}", row["created_by"])
            or type(row["nonce"]) is not bytes
            or len(row["nonce"]) != 12
            or type(row["ciphertext"]) is not bytes
            or not 16 <= len(row["ciphertext"]) <= 32768
        ):
            raise ValueError("invalid_inventory_row")
        return StoredInventoryItem.model_validate_json(
            self._cipher.decrypt(
                row["nonce"],
                row["ciphertext"],
                self._aad(row["id"], row["revision"], row["created_by"]),
            )
        )

    def _transaction(self, actor, core_id, home_id, *, write=False):
        self.auth.rate_limit(
            [("inventory_write" if write else "inventory_read", actor.id, 120)]
        )
        return self.db.transaction()

    def _actor(self, connection, actor, core_id, home_id):
        self.auth.assert_current(connection, actor)
        if actor.must_change_password:
            raise ApiError("password_change_required", 403)
        self._scope(core_id, home_id)
        row = connection.execute(
            "SELECT id,role,disabled,must_change_password FROM users WHERE id=?", (actor.id,)
        ).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("unauthorized", 401)
        return row

    def _row(self, connection, item_id):
        if not isinstance(item_id, str) or not re.fullmatch(r"[0-9a-f]{32}", item_id):
            raise ApiError("invalid_request")
        row = connection.execute(
            "SELECT * FROM inventory_items WHERE id=?", (item_id,)
        ).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        return row

    def _visible(self, actor_row, row, stored):
        if (
            actor_row["role"] != "admin"
            and actor_row["id"] != stored.createdBy
            and actor_row["id"] not in stored.readerIds
        ):
            raise ApiError("not_found", 404)

    def _public(self, row, stored):
        return InventoryItem(
            schemaVersion=1,
            ref=InventoryRef(
                **self.scope.model_dump(), kind="inventory_item", id=row["id"]
            ),
            revision=row["revision"],
            label=stored.label,
            links=stored.links,
        ).model_dump()

    def _qr(self, item_id):
        return InventoryQr(
            schemaVersion=1,
            format="larenor_inventory_v1",
            value=(
                f"larenor:inventory:v1:{self.scope.coreId}:"
                f"{self.scope.homeId}:{item_id}"
            ),
        ).model_dump()

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM inventory_items ORDER BY id LIMIT ?", (schema.MAX_ITEMS + 1,)
                ).fetchall()
                if len(rows) > schema.MAX_ITEMS:
                    raise ValueError("inventory_capacity")
                for row in rows:
                    stored = self._decode(row)
                    if stored.createdBy != row["created_by"]:
                        raise ValueError("creator_mismatch")
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise StartupError("inventory_storage_invalid") from None

    def create(self, actor, core_id, home_id, value):
        body = CreateInventoryItem.model_validate(value)
        item_id = uuid.uuid4().hex
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                actor_row = self._actor(connection, actor, core_id, home_id)
                if actor_row["role"] != "admin":
                    raise ApiError("forbidden", 403)
                count = connection.execute(
                    "SELECT COUNT(*) FROM inventory_items"
                ).fetchone()[0]
                if count >= schema.MAX_ITEMS:
                    raise ApiError("revision_conflict", 409)
                if body.readerIds:
                    rows = connection.execute(
                        "SELECT id,disabled,must_change_password FROM users WHERE id IN ("
                        + ",".join("?" for _ in body.readerIds)
                        + ")",
                        tuple(body.readerIds),
                    ).fetchall()
                    if (
                        {row["id"] for row in rows} != set(body.readerIds)
                        or any(
                            row["disabled"] or row["must_change_password"]
                            for row in rows
                        )
                    ):
                        raise ApiError("invalid_request")
                links = InventoryLinks(
                    schemaVersion=1,
                    roomId=body.roomId,
                    deviceId=body.deviceId,
                    documentIds=body.documentIds,
                )
                stored = StoredInventoryItem(
                    label=body.label,
                    links=links,
                    readerIds=body.readerIds,
                    createdBy=actor.id,
                )
                plain = stored.model_dump_json().encode("utf-8")
                if len(plain) > 32752:
                    raise ApiError("invalid_request")
                nonce = secrets.token_bytes(12)
                connection.execute(
                    "INSERT INTO inventory_items VALUES(?,?,?,?,?)",
                    (
                        item_id,
                        1,
                        actor.id,
                        nonce,
                        self._cipher.encrypt(
                            nonce, plain, self._aad(item_id, 1, actor.id)
                        ),
                    ),
                )
                row = self._row(connection, item_id)
                return {"item": self._public(row, stored), "qr": self._qr(item_id)}
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def get(self, actor, core_id, home_id, item_id):
        try:
            with self._transaction(actor, core_id, home_id) as connection:
                actor_row = self._actor(connection, actor, core_id, home_id)
                row = self._row(connection, item_id)
                stored = self._decode(row)
                self._visible(actor_row, row, stored)
                return {"item": self._public(row, stored)}
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def resolve(self, actor, core_id, home_id, qr):
        value = InventoryQr.model_validate(qr)
        match = re.fullmatch(
            r"larenor:inventory:v1:([0-9a-f]{32}):([0-9a-f]{32}):([0-9a-f]{32})",
            value.value,
        )
        if match is None:
            raise ApiError("invalid_request")
        qr_core, qr_home, item_id = match.groups()
        if (qr_core, qr_home) != (core_id, home_id):
            raise ApiError("not_found", 404)
        return self.get(actor, core_id, home_id, item_id)
