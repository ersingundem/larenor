import base64
import json
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
    def __init__(self, db, auth, settings, key, context, resources, blobs):
        self.db, self.auth, self.settings, self._key = db, auth, settings, key
        self.resources, self.blobs = resources, blobs
        self.scope = HomeScope.model_validate(context.model_dump())
        self._cipher = AESGCM(key)

    @staticmethod
    def _next(revision):
        if revision >= 2**63 - 1:
            raise ApiError("revision_conflict", 409)
        return revision + 1

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
        if not self._is_visible(actor_row, stored):
            raise ApiError("not_found", 404)

    @staticmethod
    def _is_visible(actor_row, stored):
        return (
            actor_row["role"] == "admin"
            or actor_row["id"] == stored.createdBy
            or actor_row["id"] in stored.readerIds
        )

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

    def _save(self, connection, item_id, revision, created_by, stored):
        plain = StoredInventoryItem.model_validate(stored).model_dump_json().encode("utf-8")
        if len(plain) > 32752:
            raise ApiError("invalid_request")
        nonce = secrets.token_bytes(12)
        connection.execute(
            "INSERT INTO inventory_items VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET "
            "revision=excluded.revision,nonce=excluded.nonce,ciphertext=excluded.ciphertext",
            (item_id, revision, created_by, nonce,
             self._cipher.encrypt(nonce, plain, self._aad(item_id, revision, created_by))),
        )

    def _validate_links(self, connection, links, *, missing="invalid_request"):
        expected = []
        if links.roomId is not None:
            expected.append((links.roomId, "room"))
        if links.deviceId is not None:
            expected.append((links.deviceId, "resource"))
        for identity, kind in expected:
            self.resources.validate_reference(
                connection, identity, kind, missing=missing
            )
        for identity in links.documentIds:
            self.resources.validate_reference(
                connection, identity, "resource", missing=missing
            )
            self.blobs.validate_reference(
                connection, self.scope.coreId, self.scope.homeId, identity,
                missing=missing,
            )

    def _audit_state(self, connection):
        rows = connection.execute("SELECT * FROM inventory_audit_state LIMIT 2").fetchall()
        if len(rows) != 1:
            raise ValueError("invalid_inventory_audit")
        state = rows[0]
        if (state["singleton"] != 1 or type(state["sequence"]) is not int or
                not 0 <= state["sequence"] <= schema.MAX_AUDIT or
                not re.fullmatch(r"[0-9a-f]{64}", state["head_hash"] or "") or
                not re.fullmatch(r"[0-9a-f]{64}", state["authentication_tag"] or "") or
                not secrets.compare_digest(
                    state["authentication_tag"],
                    schema.state_tag(self._key, self.scope, state["sequence"], state["head_hash"]),
                )):
            raise ValueError("invalid_inventory_audit")
        return state

    def _validate_audit(self, connection):
        state = self._audit_state(connection)
        previous = "0" * 64
        rows = connection.execute(
            "SELECT * FROM inventory_audit ORDER BY sequence LIMIT ?", (schema.MAX_AUDIT + 1,)
        ).fetchall()
        if len(rows) != state["sequence"] or len(rows) > schema.MAX_AUDIT:
            raise ValueError("invalid_inventory_audit")
        for expected, row in enumerate(rows, 1):
            if (row["sequence"] != expected or row["action"] not in
                    {"create", "update", "grant", "revoke"} or
                    not re.fullmatch(r"[0-9a-f]{32}", row["item_id"] or "") or
                    not re.fullmatch(r"[0-9a-f]{32}", row["actor_id"] or "") or
                    type(row["item_revision"]) is not int or row["item_revision"] < 1 or
                    type(row["created_at"]) not in (int, float) or
                    row["previous_hash"] != previous):
                raise ValueError("invalid_inventory_audit")
            expected_hash = schema.entry_hash(
                self._key, self.scope, expected, row["item_id"], row["action"],
                row["actor_id"], row["item_revision"], row["created_at"], previous,
            )
            if not secrets.compare_digest(row["entry_hash"], expected_hash):
                raise ValueError("invalid_inventory_audit")
            previous = expected_hash
        if state["head_hash"] != previous:
            raise ValueError("invalid_inventory_audit")
        return rows

    def _append_audit(self, connection, item_id, action, actor_id, revision):
        state = self._audit_state(connection)
        if state["sequence"] >= schema.MAX_AUDIT:
            raise ApiError("revision_conflict", 409)
        sequence = state["sequence"] + 1
        created_at = self.settings.clock()
        head = schema.entry_hash(
            self._key, self.scope, sequence, item_id, action, actor_id, revision,
            created_at, state["head_hash"],
        )
        connection.execute(
            "INSERT INTO inventory_audit VALUES(?,?,?,?,?,?,?,?)",
            (sequence, item_id, action, actor_id, revision, created_at,
             state["head_hash"], head),
        )
        connection.execute(
            "UPDATE inventory_audit_state SET sequence=?,head_hash=?,authentication_tag=? "
            "WHERE singleton=1",
            (sequence, head, schema.state_tag(self._key, self.scope, sequence, head)),
        )

    def _qr(self, item_id):
        return InventoryQr(
            schemaVersion=1,
            format="larenor_inventory_v1",
            value=(
                f"larenor:inventory:v1:{self.scope.coreId}:"
                f"{self.scope.homeId}:{item_id}"
            ),
        ).model_dump()

    def _cursor_aad(self, actor_id):
        return (
            f"larenor-inventory-cursor-v1:{self.scope.coreId}:"
            f"{self.scope.homeId}:{actor_id}"
        ).encode("ascii")

    def _encode_cursor(self, actor_id, last_id):
        plain = json.dumps(
            {"schemaVersion": 1, "lastId": last_id},
            separators=(",", ":"),
        ).encode("ascii")
        nonce = secrets.token_bytes(12)
        value = base64.urlsafe_b64encode(
            nonce + self._cipher.encrypt(nonce, plain, self._cursor_aad(actor_id))
        ).decode("ascii").rstrip("=")
        if len(value) > 512:
            raise ApiError("server_unavailable", 503)
        return value

    def _decode_cursor(self, actor_id, value):
        if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{32,512}", value):
            raise ApiError("invalid_request")
        try:
            padded = value + "=" * (-len(value) % 4)
            raw = base64.b64decode(padded, altchars=b"-_", validate=True)
            if base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=") != value:
                raise ValueError("non_canonical_cursor")
            if not 28 <= len(raw) <= 384:
                raise ValueError("invalid_cursor_size")
            decoded = json.loads(
                self._cipher.decrypt(
                    raw[:12],
                    raw[12:],
                    self._cursor_aad(actor_id),
                ).decode("ascii")
            )
            if (
                not isinstance(decoded, dict)
                or set(decoded) != {"schemaVersion", "lastId"}
                or decoded["schemaVersion"] != 1
                or not isinstance(decoded["lastId"], str)
                or not re.fullmatch(r"[0-9a-f]{32}", decoded["lastId"])
            ):
                raise ValueError("invalid_cursor_payload")
            return decoded["lastId"]
        except (InvalidTag, ValueError, TypeError, UnicodeError, json.JSONDecodeError):
            raise ApiError("invalid_request") from None

    def list_items(self, actor, core_id, home_id, *, limit=25, cursor=None):
        if type(limit) is not int or not 1 <= limit <= 100:
            raise ApiError("invalid_request")
        try:
            with self._transaction(actor, core_id, home_id) as connection:
                actor_row = self._actor(connection, actor, core_id, home_id)
                last_id = (
                    self._decode_cursor(actor_row["id"], cursor)
                    if cursor is not None
                    else ""
                )
                self._validate_audit(connection)
                rows = connection.execute(
                    "SELECT * FROM inventory_items WHERE id>? ORDER BY id LIMIT ?",
                    (last_id, schema.MAX_ITEMS + 1),
                ).fetchall()
                if len(rows) > schema.MAX_ITEMS:
                    raise ValueError("inventory_capacity")
                visible = []
                for row in rows:
                    stored = self._decode(row)
                    if not self._is_visible(actor_row, stored):
                        continue
                    self._validate_links(connection, stored.links, missing="not_found")
                    visible.append((row, stored))
                    if len(visible) > limit:
                        break
                page = visible[:limit]
                return {
                    "schemaVersion": 1,
                    "verified": True,
                    "items": [self._public(row, stored) for row, stored in page],
                    "nextCursor": (
                        self._encode_cursor(actor_row["id"], page[-1][0]["id"])
                        if len(visible) > limit
                        else None
                    ),
                }
        except ApiError:
            raise
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

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
                self._validate_audit(connection)
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
                self._validate_audit(connection)
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
                self._validate_links(connection, links)
                stored = StoredInventoryItem(
                    label=body.label,
                    links=links,
                    readerIds=body.readerIds,
                    createdBy=actor.id,
                )
                self._save(connection, item_id, 1, actor.id, stored)
                self._append_audit(connection, item_id, "create", actor.id, 1)
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
                self._validate_audit(connection)
                self._validate_links(connection, stored.links, missing="not_found")
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

    def update(self, actor, core_id, home_id, item_id, value):
        from .models import UpdateInventoryItem
        body = UpdateInventoryItem.model_validate(value)
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                actor_row = self._actor(connection, actor, core_id, home_id)
                if actor_row["role"] != "admin":
                    raise ApiError("forbidden", 403)
                self._validate_audit(connection)
                row = self._row(connection, item_id)
                if row["revision"] != body.expectedRevision:
                    raise ApiError("revision_conflict", 409)
                stored = self._decode(row)
                links = InventoryLinks(schemaVersion=1, roomId=body.roomId,
                    deviceId=body.deviceId, documentIds=body.documentIds)
                self._validate_links(connection, links)
                if (stored.label, stored.links) != (body.label, links):
                    revision = self._next(row["revision"])
                    stored = StoredInventoryItem(label=body.label, links=links,
                        readerIds=stored.readerIds, createdBy=stored.createdBy)
                    self._save(connection, item_id, revision, row["created_by"], stored)
                    self._append_audit(connection, item_id, "update", actor.id, revision)
                    row = self._row(connection, item_id)
                return {"item": self._public(row, stored)}
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def grants(self, actor, core_id, home_id, item_id):
        try:
            with self._transaction(actor, core_id, home_id) as connection:
                actor_row = self._actor(connection, actor, core_id, home_id)
                if actor_row["role"] != "admin":
                    raise ApiError("forbidden", 403)
                self._validate_audit(connection)
                row = self._row(connection, item_id)
                stored = self._decode(row)
                return {"schemaVersion": 1, "itemRevision": row["revision"],
                    "grants": [{"schemaVersion": 1, "subjectId": value}
                               for value in sorted(stored.readerIds)]}
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def set_grant(self, actor, core_id, home_id, item_id, subject_id, value, *, revoke=False):
        from .models import SetInventoryGrant
        body = SetInventoryGrant.model_validate(value)
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                actor_row = self._actor(connection, actor, core_id, home_id)
                if actor_row["role"] != "admin":
                    raise ApiError("forbidden", 403)
                self._validate_audit(connection)
                row = self._row(connection, item_id)
                if row["revision"] != body.expectedRevision:
                    raise ApiError("revision_conflict", 409)
                stored = self._decode(row)
                readers = set(stored.readerIds)
                if not revoke:
                    subject = connection.execute(
                        "SELECT disabled,must_change_password FROM users WHERE id=?", (subject_id,)
                    ).fetchone()
                    if subject is None or subject["disabled"] or subject["must_change_password"]:
                        raise ApiError("not_found", 404)
                    readers.add(subject_id)
                else:
                    readers.discard(subject_id)
                ordered = sorted(readers)
                if ordered != sorted(stored.readerIds):
                    revision = self._next(row["revision"])
                    stored = StoredInventoryItem(label=stored.label, links=stored.links,
                        readerIds=ordered, createdBy=stored.createdBy)
                    self._save(connection, item_id, revision, row["created_by"], stored)
                    self._append_audit(connection, item_id,
                        "revoke" if revoke else "grant", actor.id, revision)
                    row = self._row(connection, item_id)
                return {"item": self._public(row, stored)}
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def history(self, actor, core_id, home_id, item_id):
        try:
            with self._transaction(actor, core_id, home_id) as connection:
                actor_row = self._actor(connection, actor, core_id, home_id)
                item_row = self._row(connection, item_id)
                stored = self._decode(item_row)
                self._visible(actor_row, item_row, stored)
                rows = self._validate_audit(connection)
                return {"schemaVersion": 1, "verified": True, "entries": [
                    {"schemaVersion": 1, "sequence": row["sequence"],
                     "action": row["action"], "actorId": row["actor_id"],
                     "itemRevision": row["item_revision"], "createdAt": row["created_at"]}
                    for row in rows if row["item_id"] == item_id
                ][-100:]}
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None
