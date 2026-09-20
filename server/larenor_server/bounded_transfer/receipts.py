import hashlib
import hmac
import json
import sqlite3

from ..errors import ApiError, StartupError
from . import schema


def _json(value) -> bytes:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":")).encode("ascii")


class TransferReceipts:
    def __init__(self, db, settings, key):
        self.db, self.clock, self.key = db, settings.clock, key

    def _tag(self, row):
        values = [row[key] for key in (
            "request_id", "actor_id", "core_id", "home_id", "resource_id",
            "request_hash", "state", "trace_id", "content_length", "sha256",
            "content_type", "service_revision", "created_at", "updated_at",
        )]
        return hmac.new(
            self.key, b"larenor-bounded-transfer-receipt-v1\0" + _json(values), hashlib.sha256
        ).hexdigest()

    def _verify(self, row):
        if not hmac.compare_digest(row["authentication_tag"], self._tag(row)):
            raise ValueError("invalid_receipt")

    def validate_and_recover(self):
        try:
            with self.db.transaction() as connection:
                rows = connection.execute(
                    "SELECT * FROM bounded_transfer_receipts ORDER BY created_at,request_id LIMIT ?",
                    (schema.MAX_RECEIPTS + 1,),
                ).fetchall()
                if len(rows) > schema.MAX_RECEIPTS:
                    raise ValueError("receipt_limit")
                for old in rows:
                    self._verify(old)
                    if old["state"] == "accepted":
                        row = dict(old)
                        row["state"], row["updated_at"] = "interrupted", self.clock()
                        connection.execute(
                            "UPDATE bounded_transfer_receipts SET state=?,updated_at=?,authentication_tag=? WHERE request_id=?",
                            (row["state"], row["updated_at"], self._tag(row), row["request_id"]),
                        )
        except (sqlite3.Error, ValueError, TypeError):
            raise StartupError("bounded_transfer_storage_invalid") from None

    @staticmethod
    def request_hash(actor_id, core_id, home_id, resource_id, body, descriptor):
        return hashlib.sha256(_json([
            actor_id, core_id, home_id, resource_id, body.model_dump(),
            {"serviceRevision": descriptor.service_revision,
             "contentLength": len(descriptor.content),
             "sha256": hashlib.sha256(descriptor.content).hexdigest(),
             "contentType": descriptor.content_type},
        ])).hexdigest()

    def accept(self, actor, core_id, home_id, resource_id, body, descriptor):
        digest = self.request_hash(actor.id, core_id, home_id, resource_id, body, descriptor)
        now = self.clock()
        row = {
            "request_id": body.requestId, "actor_id": actor.id, "core_id": core_id,
            "home_id": home_id, "resource_id": resource_id, "request_hash": digest,
            "state": "accepted", "trace_id": body.requestId,
            "content_length": len(descriptor.content),
            "sha256": hashlib.sha256(descriptor.content).hexdigest(),
            "content_type": descriptor.content_type,
            "service_revision": descriptor.service_revision,
            "created_at": now, "updated_at": now,
        }
        with self.db.transaction() as connection:
            old = connection.execute(
                "SELECT * FROM bounded_transfer_receipts WHERE request_id=?", (body.requestId,)
            ).fetchone()
            if old is not None:
                self._verify(old)
                exact = old["actor_id"] == actor.id and old["request_hash"] == digest
                raise ApiError("transfer_replay" if exact else "idempotency_conflict", 409)
            if connection.execute("SELECT COUNT(*) FROM bounded_transfer_receipts").fetchone()[0] >= schema.MAX_RECEIPTS:
                raise ApiError("bounded_transfer_limit_reached", 429)
            row["authentication_tag"] = self._tag(row)
            connection.execute(
                "INSERT INTO bounded_transfer_receipts VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                tuple(row.values()),
            )

    def reject_existing(self, actor, request_id):
        """Fail before provider access when an opaque operation id is already durable."""
        with self.db.connection() as connection:
            old = connection.execute(
                "SELECT * FROM bounded_transfer_receipts WHERE request_id=?", (request_id,)
            ).fetchone()
            if old is None:
                return
            self._verify(old)
            raise ApiError(
                "transfer_replay" if old["actor_id"] == actor.id else "idempotency_conflict",
                409,
            )

    def finish(self, request_id, state):
        try:
            with self.db.transaction() as connection:
                old = connection.execute(
                    "SELECT * FROM bounded_transfer_receipts WHERE request_id=?", (request_id,)
                ).fetchone()
                if old is None:
                    raise ValueError("missing_receipt")
                self._verify(old)
                if old["state"] != "accepted":
                    return
                row = dict(old)
                row["state"], row["updated_at"] = state, self.clock()
                connection.execute(
                    "UPDATE bounded_transfer_receipts SET state=?,updated_at=?,authentication_tag=? WHERE request_id=?",
                    (state, row["updated_at"], self._tag(row), request_id),
                )
        except (sqlite3.Error, ValueError, TypeError):
            raise ApiError("server_unavailable", 503) from None

    @staticmethod
    def _public(row):
        return {
            "requestId": row["request_id"], "traceId": row["trace_id"],
            "state": row["state"], "contentLength": row["content_length"],
            "sha256": row["sha256"], "contentType": row["content_type"],
            "serviceRevision": row["service_revision"],
            "createdAt": row["created_at"], "updatedAt": row["updated_at"],
        }

    def one(self, actor, resource_id, request_id):
        with self.db.connection() as connection:
            row = connection.execute(
                "SELECT * FROM bounded_transfer_receipts WHERE request_id=? AND resource_id=?",
                (request_id, resource_id),
            ).fetchone()
            if row is None or (row["actor_id"] != actor.id and actor.role != "admin"):
                raise ApiError("not_found", 404)
            self._verify(row)
            return {"receipt": self._public(row)}

    def history(self, actor, resource_id, limit):
        with self.db.connection() as connection:
            if actor.role == "admin":
                rows = connection.execute(
                    "SELECT * FROM bounded_transfer_receipts WHERE resource_id=? ORDER BY created_at DESC,request_id DESC LIMIT ?",
                    (resource_id, limit),
                ).fetchall()
            else:
                rows = connection.execute(
                    "SELECT * FROM bounded_transfer_receipts WHERE resource_id=? AND actor_id=? ORDER BY created_at DESC,request_id DESC LIMIT ?",
                    (resource_id, actor.id, limit),
                ).fetchall()
            for row in rows:
                self._verify(row)
            return {"receipts": [self._public(row) for row in rows]}
