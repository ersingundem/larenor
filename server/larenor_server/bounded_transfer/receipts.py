import hashlib
import hmac
import json
import math
import re
import sqlite3

from ..errors import ApiError, StartupError
from . import events, schema


_IDENTITY = re.compile(r"^[0-9a-f]{32}$")
_DIGEST = re.compile(r"^[0-9a-f]{64}$")
_CONTENT_TYPE = re.compile(r"^[A-Za-z0-9!#$&^_.+\-/;= ]{1,128}$")


def _json(value) -> bytes:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":")).encode("ascii")


class TransferReceipts:
    def __init__(self, db, settings, key):
        self.db, self.clock, self.key = db, settings.clock, key

    def _tag(self, row):
        values = [row[key] for key in (
            "request_id", "actor_id", "core_id", "home_id", "resource_id",
            "envelope_hash", "state", "trace_id", "content_length", "sha256",
            "content_type", "service_revision", "created_at", "updated_at",
        )]
        return hmac.new(
            self.key, b"larenor-bounded-transfer-receipt-v1\0" + _json(values), hashlib.sha256
        ).hexdigest()

    def _verify(self, row):
        identities = [row[key] for key in (
            "request_id", "actor_id", "core_id", "home_id", "resource_id", "trace_id"
        )]
        valid = (
            all(type(value) is str and _IDENTITY.fullmatch(value) for value in identities)
            and row["request_id"] == row["trace_id"]
            and type(row["envelope_hash"]) is str and _DIGEST.fullmatch(row["envelope_hash"])
            and row["state"] in {"accepted", "completed", "interrupted"}
            and type(row["content_length"]) is int and 0 <= row["content_length"] <= 256 * 1024
            and type(row["sha256"]) is str and _DIGEST.fullmatch(row["sha256"])
            and type(row["content_type"]) is str and _CONTENT_TYPE.fullmatch(row["content_type"])
            and "\r" not in row["content_type"] and "\n" not in row["content_type"]
            and type(row["service_revision"]) is int and 1 <= row["service_revision"] <= 2**63 - 1
            and type(row["created_at"]) is float and math.isfinite(row["created_at"])
            and type(row["updated_at"]) is float and math.isfinite(row["updated_at"])
            and 0 <= row["created_at"] <= row["updated_at"]
            and type(row["authentication_tag"]) is str and _DIGEST.fullmatch(row["authentication_tag"])
        )
        if not valid or not hmac.compare_digest(row["authentication_tag"], self._tag(row)):
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
                events.validate(connection, self.key)
                for old in rows:
                    if old["state"] == "accepted":
                        row = dict(old)
                        row["state"], row["updated_at"] = (
                            "interrupted",
                            max(old["updated_at"], self.clock()),
                        )
                        connection.execute(
                            "UPDATE bounded_transfer_receipts SET state=?,updated_at=?,authentication_tag=? WHERE request_id=?",
                            (row["state"], row["updated_at"], self._tag(row), row["request_id"]),
                        )
                        events.append(connection, self.key, row, kind="result")
                events.validate(connection, self.key)
        except (sqlite3.Error, ValueError, TypeError):
            raise StartupError("bounded_transfer_storage_invalid") from None

    @staticmethod
    def envelope_hash(actor_id, core_id, home_id, resource_id, body):
        values = body.model_dump()
        if body.resumeRequestId is None:
            values.pop("resumeRequestId")
            values.pop("resumeOffset")
        return hashlib.sha256(_json([
            actor_id, core_id, home_id, resource_id, values,
        ])).hexdigest()

    def authorize_resume(self, actor, core_id, home_id, resource_id, body,
                         descriptor):
        """Bind a new request to one exact interrupted receipt."""
        try:
            with self.db.connection() as connection:
                row = connection.execute(
                    "SELECT * FROM bounded_transfer_receipts WHERE request_id=?",
                    (body.resumeRequestId,),
                ).fetchone()
                if row is None or row["actor_id"] != actor.id:
                    raise ApiError("not_found", 404)
                self._verify(row)
                if (
                    row["core_id"] != core_id
                    or row["home_id"] != home_id
                    or row["resource_id"] != resource_id
                    or row["state"] != "interrupted"
                    or row["content_length"] != len(descriptor.content)
                    or row["sha256"] != hashlib.sha256(descriptor.content).hexdigest()
                    or row["content_type"] != descriptor.content_type
                    or row["service_revision"] != descriptor.service_revision
                    or not 0 < body.resumeOffset <= row["content_length"]
                ):
                    raise ApiError("revision_conflict", 409)
        except (sqlite3.Error, ValueError, TypeError):
            raise ApiError("server_unavailable", 503) from None

    def cancel(self, actor, resource_id, request_id):
        try:
            with self.db.transaction() as connection:
                row = connection.execute(
                    "SELECT * FROM bounded_transfer_receipts "
                    "WHERE request_id=? AND resource_id=?",
                    (request_id, resource_id),
                ).fetchone()
                if row is None or (row["actor_id"] != actor.id
                                   and actor.role != "admin"):
                    raise ApiError("not_found", 404)
                self._verify(row)
                if row["state"] == "completed":
                    raise ApiError("revision_conflict", 409)
                if row["state"] == "accepted":
                    changed = dict(row)
                    changed["state"] = "interrupted"
                    changed["updated_at"] = max(row["updated_at"], self.clock())
                    connection.execute(
                        "UPDATE bounded_transfer_receipts "
                        "SET state=?,updated_at=?,authentication_tag=? "
                        "WHERE request_id=?",
                        (changed["state"], changed["updated_at"],
                         self._tag(changed), request_id),
                    )
                    events.append(connection, self.key, changed, kind="result")
                    row = changed
                return {"receipt": self._public(row)}
        except (sqlite3.Error, ValueError, TypeError):
            raise ApiError("server_unavailable", 503) from None

    def accept(self, actor, core_id, home_id, resource_id, body, descriptor):
        digest = self.envelope_hash(actor.id, core_id, home_id, resource_id, body)
        now = self.clock()
        row = {
            "request_id": body.requestId, "actor_id": actor.id, "core_id": core_id,
            "home_id": home_id, "resource_id": resource_id, "envelope_hash": digest,
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
                exact = old["actor_id"] == actor.id and old["envelope_hash"] == digest
                raise ApiError("transfer_replay" if exact else "idempotency_conflict", 409)
            if connection.execute("SELECT COUNT(*) FROM bounded_transfer_receipts").fetchone()[0] >= schema.MAX_RECEIPTS:
                raise ApiError("bounded_transfer_limit_reached", 429)
            row["authentication_tag"] = self._tag(row)
            connection.execute(
                "INSERT INTO bounded_transfer_receipts VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                tuple(row.values()),
            )
            events.append(connection, self.key, row, kind="accepted")

    def reject_existing(self, actor, core_id, home_id, resource_id, body):
        """Fail before provider access when an opaque operation id is already durable."""
        with self.db.connection() as connection:
            old = connection.execute(
                "SELECT * FROM bounded_transfer_receipts WHERE request_id=?", (body.requestId,)
            ).fetchone()
            if old is None:
                return
            self._verify(old)
            digest = self.envelope_hash(actor.id, core_id, home_id, resource_id, body)
            raise ApiError(
                "transfer_replay"
                if old["actor_id"] == actor.id and old["envelope_hash"] == digest
                else "idempotency_conflict",
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
                row["state"], row["updated_at"] = (
                    state,
                    max(old["updated_at"], self.clock()),
                )
                connection.execute(
                    "UPDATE bounded_transfer_receipts SET state=?,updated_at=?,authentication_tag=? WHERE request_id=?",
                    (state, row["updated_at"], self._tag(row), request_id),
                )
                events.append(connection, self.key, row, kind="result")
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

    def events(self, actor, resource_id, ref, *, after, limit):
        try:
            with self.db.connection() as connection:
                return events.history(
                    connection,
                    self.key,
                    actor,
                    resource_id,
                    ref,
                    after=after,
                    limit=limit,
                )
        except ApiError:
            raise
        except (sqlite3.Error, ValueError, TypeError, OverflowError):
            raise ApiError("server_unavailable", 503) from None
