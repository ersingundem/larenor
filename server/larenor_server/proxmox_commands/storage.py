import hashlib
import hmac
import json
import re
import secrets
import sqlite3

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from .models import PowerJournalEvent, PowerReceipt
from .schema import (EMPTY_HEAD, MAX_JOURNAL_EVENTS, MAX_RECEIPTS,
                     journal_state_tag, state_tag)


class PowerReceiptStore:
    def __init__(self, db, settings, key):
        self.db, self.settings, self.key, self.cipher = db, settings, key, AESGCM(key)

    @staticmethod
    def _aad(request_id, resource_id, user_id):
        return f"larenor-proxmox-power-v1:{request_id}:{resource_id}:{user_id}".encode("ascii")

    def _state(self, c):
        rows = c.execute("SELECT * FROM proxmox_power_state LIMIT 2").fetchall()
        if len(rows) != 1 or rows[0]["singleton"] != 1:
            raise ValueError("invalid_state")
        count = rows[0]["receipt_count"]
        if type(count) is not int or not 0 <= count <= MAX_RECEIPTS or not hmac.compare_digest(rows[0]["authentication_tag"], state_tag(self.key, count)):
            raise ValueError("invalid_state")
        return count

    def _decode(self, row):
        if type(row["nonce"]) is not bytes or len(row["nonce"]) != 12 or type(row["ciphertext"]) is not bytes:
            raise ValueError("invalid_receipt")
        return PowerReceipt.model_validate_json(self.cipher.decrypt(row["nonce"], row["ciphertext"], self._aad(row["request_id"], row["resource_id"], row["user_id"])))

    def _journal_state(self, c):
        rows = c.execute("SELECT * FROM proxmox_power_journal_state LIMIT 2").fetchall()
        if len(rows) != 1 or rows[0]["singleton"] != 1:
            raise ValueError("invalid_journal_state")
        count, head = rows[0]["event_count"], rows[0]["head_hash"]
        if (type(count) is not int or not 0 <= count <= MAX_JOURNAL_EVENTS
                or not isinstance(head, str) or not re.fullmatch(r"[0-9a-f]{64}", head)
                or not hmac.compare_digest(rows[0]["authentication_tag"], journal_state_tag(self.key, count, head))):
            raise ValueError("invalid_journal_state")
        return count, head

    def _event_hash(self, values):
        plain = json.dumps(values, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")
        return hmac.new(self.key, b"larenor-proxmox-journal-entry-v1\0" + plain, hashlib.sha256).hexdigest()

    def _event_values(self, row):
        return {key: row[key] for key in (
            "sequence", "resource_id", "user_id", "request_id", "event_kind", "action", "state",
            "result_code", "user_revision", "resource_revision", "acl_revision", "binding_revision",
            "service_revision", "status_revision", "operation_ref", "emitted_at", "previous_hash",
        )}

    def _verify_journal(self, c):
        count, head = self._journal_state(c)
        previous = EMPTY_HEAD
        rows = c.execute("SELECT * FROM proxmox_power_journal ORDER BY sequence LIMIT ?", (MAX_JOURNAL_EVENTS + 1,)).fetchall()
        if len(rows) != count:
            raise ValueError("invalid_journal_count")
        for index, row in enumerate(rows, 1):
            if row["sequence"] != index or row["previous_hash"] != previous:
                raise ValueError("invalid_journal_chain")
            PowerJournalEvent.model_validate({
                "schemaVersion": 1,
                "sequence": row["sequence"], "eventKind": row["event_kind"],
                "requestId": row["request_id"], "action": row["action"], "state": row["state"],
                "resultCode": row["result_code"], "userRevision": row["user_revision"],
                "resourceRevision": row["resource_revision"], "aclRevision": row["acl_revision"],
                "bindingRevision": row["binding_revision"], "serviceRevision": row["service_revision"],
                "statusRevision": row["status_revision"], "operationRef": row["operation_ref"],
                "emittedAt": row["emitted_at"],
            })
            calculated = self._event_hash(self._event_values(row))
            if not hmac.compare_digest(row["entry_hash"], calculated):
                raise ValueError("invalid_journal_entry")
            previous = calculated
        if not hmac.compare_digest(previous, head):
            raise ValueError("invalid_journal_head")
        return count, head

    def _append(self, c, *, resource_id, user_id, request_id, event_kind, action, state,
                result_code, user_revision, resource_revision, acl_revision, binding_revision,
                service_revision, status_revision, operation_ref, emitted_at):
        count, head = self._verify_journal(c)
        if count >= MAX_JOURNAL_EVENTS:
            raise ApiError("revision_conflict", 409)
        sequence = count + 1
        values = {
            "sequence": sequence, "resource_id": resource_id, "user_id": user_id,
            "request_id": request_id, "event_kind": event_kind, "action": action,
            "state": state, "result_code": result_code, "user_revision": user_revision,
            "resource_revision": resource_revision, "acl_revision": acl_revision,
            "binding_revision": binding_revision, "service_revision": service_revision,
            "status_revision": status_revision, "operation_ref": operation_ref,
            "emitted_at": emitted_at, "previous_hash": head,
        }
        entry_hash = self._event_hash(values)
        c.execute(
            "INSERT INTO proxmox_power_journal VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            tuple(values[key] for key in values) + (entry_hash,),
        )
        c.execute(
            "UPDATE proxmox_power_journal_state SET event_count=?,head_hash=?,authentication_tag=? WHERE singleton=1",
            (sequence, entry_hash, journal_state_tag(self.key, sequence, entry_hash)),
        )

    def validate_storage(self):
        try:
            with self.db.connection() as c:
                count = self._state(c)
                rows = c.execute("SELECT * FROM proxmox_power_receipts LIMIT ?", (MAX_RECEIPTS + 1,)).fetchall()
                if len(rows) != count:
                    raise ValueError("invalid_count")
                for row in rows:
                    self._decode(row)
                self._verify_journal(c)
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise StartupError("proxmox_power_storage_invalid") from None

    def get(self, request_id, *, resource_id=None, user_id=None):
        try:
            with self.db.connection() as c:
                self._state(c)
                row = c.execute("SELECT * FROM proxmox_power_receipts WHERE request_id=?", (request_id,)).fetchone()
                if row is None:
                    return None
                if resource_id is not None and row["resource_id"] != resource_id:
                    return None
                if user_id is not None and row["user_id"] != user_id:
                    return None
                return self._decode(row)
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def put(self, receipt, resource_id, user_id):
        receipt = PowerReceipt.model_validate(receipt)
        plain = receipt.model_dump_json().encode("utf-8")
        if len(plain) > 4096:
            raise ApiError("invalid_request")
        try:
            with self.db.transaction() as c:
                count = self._state(c)
                old = c.execute("SELECT * FROM proxmox_power_receipts WHERE request_id=?", (receipt.requestId,)).fetchone()
                if old is not None:
                    prior = self._decode(old)
                    allowed = (
                        receipt.state in ({"executing", "unknown"} if prior.state == "accepted" else
                                          {"succeeded", "failed", "cancelled", "unknown"} if prior.state == "executing" else set())
                    )
                    if old["resource_id"] != resource_id or old["user_id"] != user_id or not allowed:
                        raise ApiError("revision_conflict", 409)
                elif count >= MAX_RECEIPTS:
                    raise ApiError("revision_conflict", 409)
                nonce = secrets.token_bytes(12)
                c.execute("INSERT INTO proxmox_power_receipts VALUES(?,?,?,?,?,?) ON CONFLICT(request_id) DO UPDATE SET nonce=excluded.nonce,ciphertext=excluded.ciphertext,updated_at=excluded.updated_at", (receipt.requestId, resource_id, user_id, nonce, self.cipher.encrypt(nonce, plain, self._aad(receipt.requestId, resource_id, user_id)), receipt.updatedAt))
                if old is None:
                    count += 1
                    c.execute("UPDATE proxmox_power_state SET receipt_count=?,authentication_tag=? WHERE singleton=1", (count, state_tag(self.key, count)))
                self._append(
                    c, resource_id=resource_id, user_id=user_id, request_id=receipt.requestId,
                    event_kind="command_status", action=receipt.action, state=receipt.state,
                    result_code=receipt.resultCode, user_revision=receipt.userRevision,
                    resource_revision=receipt.resourceRevision, acl_revision=receipt.aclRevision,
                    binding_revision=receipt.bindingRevision, service_revision=receipt.serviceRevision,
                    status_revision=receipt.statusRevision, operation_ref=receipt.operationRef,
                    emitted_at=receipt.updatedAt,
                )
        except ApiError:
            raise
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def recover_incomplete(self):
        """A process restart makes every accepted/in-flight effect uncertain."""
        with self.db.connection() as c:
            rows = c.execute("SELECT * FROM proxmox_power_receipts LIMIT ?", (MAX_RECEIPTS + 1,)).fetchall()
        for row in rows:
            receipt = self._decode(row)
            if receipt.state in ("accepted", "executing"):
                recovered = receipt.model_copy(update={
                    "state": "unknown", "resultCode": "outcome_uncertain",
                    "updatedAt": self.settings.clock(),
                })
                self.put(recovered, row["resource_id"], row["user_id"])

    def append_preview(self, body, descriptor, user_id, event_kind):
        state, code = (("previewed", "preview_created") if event_kind == "previewed"
                       else ("preview_cancelled", "preview_cancelled"))
        try:
            with self.db.transaction() as c:
                self._verify_journal(c)
                if event_kind == "previewed" and c.execute(
                        "SELECT 1 FROM proxmox_power_journal WHERE request_id=? AND event_kind='previewed'",
                        (body.requestId,)).fetchone() is not None:
                    raise ApiError("revision_conflict", 409)
                self._append(
                    c, resource_id=descriptor.resource_id, user_id=user_id,
                    request_id=body.requestId, event_kind=event_kind, action=body.action,
                    state=state, result_code=code, user_revision=body.expectedUserRevision,
                    resource_revision=body.expectedResourceRevision,
                    acl_revision=body.expectedAclRevision,
                    binding_revision=body.expectedBindingRevision,
                    service_revision=body.expectedServiceRevision,
                    status_revision=body.expectedStatusRevision, operation_ref=None,
                    emitted_at=self.settings.clock(),
                )
        except ApiError:
            raise
        except (ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def journal(self, resource_id, limit):
        if type(limit) is not int or not 1 <= limit <= 50:
            raise ApiError("invalid_request")
        try:
            with self.db.connection() as c:
                count, _head = self._verify_journal(c)
                rows = c.execute(
                    "SELECT * FROM proxmox_power_journal WHERE resource_id=? ORDER BY sequence DESC LIMIT ?",
                    (resource_id, limit),
                ).fetchall()
                entries = []
                for row in reversed(rows):
                    entries.append(PowerJournalEvent(
                        sequence=row["sequence"], eventKind=row["event_kind"],
                        requestId=row["request_id"], action=row["action"], state=row["state"],
                        resultCode=row["result_code"], userRevision=row["user_revision"],
                        resourceRevision=row["resource_revision"], aclRevision=row["acl_revision"],
                        bindingRevision=row["binding_revision"], serviceRevision=row["service_revision"],
                        statusRevision=row["status_revision"], operationRef=row["operation_ref"],
                        emittedAt=row["emitted_at"],
                    ).model_dump())
                return {"schemaVersion": 1, "entries": entries, "eventCount": count}
        except ApiError:
            raise
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None

    def integrity(self):
        try:
            with self.db.connection() as c:
                count, head = self._verify_journal(c)
            return {"schemaVersion": 1, "verified": True, "eventCount": count, "headHash": head}
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("server_unavailable", 503) from None
