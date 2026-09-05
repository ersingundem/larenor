"""One durable preparation for six components. No host inspection or execution."""

import hashlib
import json
import re
import secrets
import sqlite3
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..admin.service import utc
from ..errors import ApiError, StartupError
from .media_models import CreateMediaPreparationRequest, MediaPreparation, MediaPreparationPayload
from .stack_plan import build_media_stack_plan, verify_media_stack_plan


MAX_PREPARATIONS = 256
MAX_ACTIVE = 8
MAX_CIPHERTEXT = 131072
BINDING = ("id", "sequence", "revision", "state", "actor_id", "actor_revision", "family_id",
           "request_id", "created_at", "updated_at", "cancelled_by")


def _identifier(value):
    if type(value) is not str or not re.fullmatch(r"[0-9a-f]{32}", value):
        raise ApiError("invalid_request")


class MediaPreparationManagement:
    def __init__(self, db, auth, settings, key, plugins, context):
        self.db, self.auth, self.settings, self.plugins, self.context = db, auth, settings, plugins, context
        self._cipher = AESGCM(key)

    @staticmethod
    def _aad(row):
        return b"larenor:media:preparations:schema=1:" + json.dumps(
            {key: row[key] for key in BINDING}, sort_keys=True, separators=(",", ":")).encode("ascii")

    def _public(self, row, payload):
        return {"id": row["id"], "requestId": row["request_id"], "revision": row["revision"],
                "state": row["state"], "createdAt": utc(row["created_at"]), "updatedAt": utc(row["updated_at"]),
                "catalogCurrent": payload.plan.catalogDigest == self.plugins._catalog.digest, "plan": payload.plan}

    def _decode(self, row):
        try:
            for key in ("id", "actor_id", "family_id", "request_id"):
                if type(row[key]) is not str or not re.fullmatch(r"[0-9a-f]{32}", row[key]):
                    raise ValueError()
            for key in ("sequence", "revision", "actor_revision"):
                if type(row[key]) is not int or not 1 <= row[key] <= 2**63 - 2:
                    raise ValueError()
            if (len(row["nonce"]) != 12 or not 16 <= len(row["ciphertext"]) <= MAX_CIPHERTEXT or
                    any(type(row[key]) is not int or not 0 <= row[key] <= 253402300799
                        for key in ("created_at", "updated_at")) or row["updated_at"] < row["created_at"]):
                raise ValueError()
            if row["state"] == "prepared":
                if row["revision"] != 1 or row["cancelled_by"] is not None or row["created_at"] != row["updated_at"]:
                    raise ValueError()
            elif row["state"] == "cancelled":
                if row["revision"] != 2 or type(row["cancelled_by"]) is not str or not re.fullmatch(r"[0-9a-f]{32}", row["cancelled_by"]):
                    raise ValueError()
            else:
                raise ValueError()
            raw = self._cipher.decrypt(row["nonce"], row["ciphertext"], self._aad(row))
            payload = MediaPreparationPayload.model_validate_json(raw)
            request, plan = payload.request, payload.plan
            if (plan.preparationId != row["id"] or request.requestId != row["request_id"] or
                    request.context != self.context or plan.coreId != self.context.coreId or plan.homeId != self.context.homeId or
                    plan.settings != request.settings or plan.platform != request.platform or plan.catalogDigest != request.catalogDigest):
                raise ValueError()
            # Historical plans remain readable after a catalog upgrade. Authenticity
            # comes from the bound AEAD payload, not today's package pins.
            canonical = json.dumps(plan.model_dump(mode="json", exclude={"planHash"}), sort_keys=True,
                                   separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")
            if hashlib.sha256(canonical).hexdigest() != plan.planHash:
                raise ValueError()
            MediaPreparation.model_validate(self._public(row, payload))
            return payload
        except (InvalidTag, ValueError, TypeError, OverflowError, IndexError, RecursionError):
            raise ApiError("media_preparation_storage_unavailable", 503) from None

    def _save(self, connection, row, payload):
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(nonce, payload.model_dump_json().encode("utf-8"), self._aad(row))
        if len(ciphertext) > MAX_CIPHERTEXT:
            raise ApiError("media_preparation_storage_unavailable", 503)
        self._decode(dict(row) | {"nonce": nonce, "ciphertext": ciphertext})
        connection.execute("UPDATE media_preparations SET " + ",".join(key + "=?" for key in BINDING) +
                           ",nonce=?,ciphertext=? WHERE id=?", (*[row[key] for key in BINDING], nonce, ciphertext, row["id"]))

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                connection.execute("BEGIN")
                names = set()
                rows = connection.execute("SELECT * FROM media_preparations LIMIT ?", (MAX_PREPARATIONS + 1,))
                for index, row in enumerate(rows):
                    if index >= MAX_PREPARATIONS:
                        raise ValueError()
                    payload = self._decode(row)
                    if row["state"] == "prepared":
                        name = payload.request.settings.instanceName
                        if name in names or len(names) >= MAX_ACTIVE:
                            raise ValueError()
                        names.add(name)
        except (ApiError, ValueError, sqlite3.Error, IndexError):
            raise StartupError("invalid_media_preparations_storage") from None

    def create(self, actor, body):
        with self.db.transaction() as connection:
            actor_revision = self.plugins._assert_admin(connection, actor)
            try:
                body = CreateMediaPreparationRequest.model_validate_json(body.model_dump_json())
            except (ValueError, TypeError):
                raise ApiError("invalid_request") from None
            if body.context != self.context:
                raise ApiError("media_context_changed", 409)
            previous = connection.execute("SELECT * FROM media_preparations WHERE actor_id=? AND request_id=?",
                                          (actor.id, body.requestId)).fetchone()
            if previous:
                payload = self._decode(previous)
                if body != payload.request:
                    raise ApiError("media_preparation_conflict", 409)
                return {"preparation": self._public(previous, payload)}
            if body.catalogDigest != self.plugins._catalog.digest:
                raise ApiError("media_catalog_changed", 409)
            active = connection.execute("SELECT * FROM media_preparations WHERE state='prepared' LIMIT ?", (MAX_ACTIVE + 1,)).fetchall()
            for row in active:
                if self._decode(row).request.settings.instanceName == body.settings.instanceName:
                    raise ApiError("media_preparation_conflict", 409)
            if (len(active) >= MAX_ACTIVE or
                    connection.execute("SELECT COUNT(*) FROM media_preparations").fetchone()[0] >= MAX_PREPARATIONS):
                raise ApiError("media_preparation_limit_reached", 409)
            preparation_id = uuid.uuid4().hex
            try:
                plan = build_media_stack_plan(self.plugins._catalog, body.settings, body.platform, self.context, preparation_id)
                verify_media_stack_plan(plan, self.plugins._catalog)
            except (ValueError, TypeError):
                raise ApiError("media_catalog_changed", 409) from None
            if self.plugins._assert_admin(connection, actor) != actor_revision:
                raise ApiError("forbidden", 403)
            now = int(self.settings.clock())
            sequence = connection.execute("SELECT COALESCE(MAX(sequence),0)+1 FROM media_preparations").fetchone()[0]
            row = {"id": preparation_id, "sequence": sequence, "revision": 1, "state": "prepared",
                   "actor_id": actor.id, "actor_revision": actor_revision, "family_id": actor.family_id,
                   "request_id": body.requestId, "created_at": now, "updated_at": now, "cancelled_by": None}
            payload = MediaPreparationPayload(request=body, plan=plan)
            connection.execute("INSERT INTO media_preparations(" + ",".join(BINDING) + ",nonce,ciphertext) VALUES(" +
                               ",".join("?" for _ in range(len(BINDING) + 2)) + ")", (*[row[key] for key in BINDING], b"", b""))
            self._save(connection, row, payload)
            return {"preparation": self._public(row, payload)}

    def get(self, actor, preparation_id):
        _identifier(preparation_id)
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self.plugins._assert_admin(connection, actor)
            row = connection.execute("SELECT * FROM media_preparations WHERE id=?", (preparation_id,)).fetchone()
            if row is None:
                raise ApiError("not_found", 404)
            return {"preparation": self._public(row, self._decode(row))}

    def list(self, actor, *, before=None, limit=10):
        if (type(limit) is not int or not 1 <= limit <= 10 or
                before is not None and (type(before) is not int or not 1 <= before <= 2**63 - 1)):
            raise ApiError("invalid_request")
        with self.db.connection() as connection:
            connection.execute("BEGIN")
            self.plugins._assert_admin(connection, actor)
            rows = connection.execute("SELECT * FROM media_preparations WHERE sequence < ? ORDER BY sequence DESC LIMIT ?",
                                      (before or 2**63 - 1, limit + 1)).fetchall()
            return {"preparations": [self._public(row, self._decode(row)) for row in rows[:limit]],
                    "nextBefore": rows[limit - 1]["sequence"] if len(rows) > limit else None}

    def cancel(self, actor, preparation_id, body):
        _identifier(preparation_id)
        if type(body.expectedRevision) is not int or body.expectedRevision not in (1, 2):
            raise ApiError("invalid_request")
        with self.db.transaction() as connection:
            self.plugins._assert_admin(connection, actor)
            row = connection.execute("SELECT * FROM media_preparations WHERE id=?", (preparation_id,)).fetchone()
            if row is None:
                raise ApiError("not_found", 404)
            payload = self._decode(row)
            if body.expectedRevision != row["revision"]:
                raise ApiError("revision_conflict", 409)
            if row["state"] == "cancelled":
                return {"preparation": self._public(row, payload)}
            changed = dict(row) | {"revision": 2, "state": "cancelled", "cancelled_by": actor.id,
                                  "updated_at": max(row["updated_at"], int(self.settings.clock()))}
            self._save(connection, changed, payload)
            return {"preparation": self._public(changed, payload)}
