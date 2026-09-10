import hmac
import secrets
import sqlite3

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from .models import PowerReceipt
from .schema import MAX_RECEIPTS, state_tag


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

    def validate_storage(self):
        try:
            with self.db.connection() as c:
                count = self._state(c)
                rows = c.execute("SELECT * FROM proxmox_power_receipts LIMIT ?", (MAX_RECEIPTS + 1,)).fetchall()
                if len(rows) != count:
                    raise ValueError("invalid_count")
                for row in rows:
                    self._decode(row)
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
