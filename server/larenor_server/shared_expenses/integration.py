import hashlib
import hmac
import json

from ..errors import ApiError
from .service import ExpenseStore, HouseholdAccounts


class SharedExpenseService:
    def __init__(self, db, auth, settings, context, key: bytes):
        self.db, self.auth, self.settings, self.context = db, auth, settings, context
        self.store = ExpenseStore(
            db,
            encryption_key=hmac.new(
                key, b"larenor-shared-expense-encryption-v1", hashlib.sha256
            ).digest(),
            audit_key=hmac.new(
                key, b"larenor-shared-expense-audit-v1", hashlib.sha256
            ).digest(),
        )
        self._members_key = hmac.new(
            key, b"larenor-shared-expense-members-v1", hashlib.sha256
        ).digest()

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.context.coreId, self.context.homeId):
            raise ApiError("not_found", 404)

    def _members(self, actor, *, write=False):
        self.auth.rate_limit(
            [
                (
                    "shared_expense_write" if write else "shared_expense_read",
                    actor.id,
                    180,
                )
            ]
        )
        with self.db.connection() as connection:
            self.auth.assert_current(connection, actor)
            rows = connection.execute(
                "SELECT id,username,role,revision FROM users WHERE disabled=0 "
                "AND must_change_password=0 ORDER BY created_at,id"
            ).fetchall()
        if not rows or not any(row["id"] == actor.id for row in rows):
            raise ApiError("invalid_session", 401)
        payload = json.dumps(
            [
                [row["id"], row["username"], row["role"], row["revision"]]
                for row in rows
            ],
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        revision = int.from_bytes(
            hmac.new(self._members_key, payload, hashlib.sha256).digest()[:8], "big"
        ) & (2**63 - 1)
        return (
            HouseholdAccounts(max(1, revision), tuple(row["id"] for row in rows)),
            {row["id"]: row["username"] for row in rows},
        )

    def _authority(self, actor, members):
        return {
            "schemaVersion": 1,
            "coreId": self.context.coreId,
            "homeId": self.context.homeId,
            "accountId": actor.id,
            "sessionId": actor.family_id,
            "membersRevision": members.revision,
        }

    @staticmethod
    def _record(record):
        return {
            "id": record.id,
            "revision": record.revision,
            "title": record.title,
            "currency": record.currency,
            "currencyScale": record.currency_scale,
            "totalMinor": record.total_minor,
            "payerId": record.payer_id,
            "shares": [
                {"accountId": share.account_id, "amountMinor": share.amount_minor}
                for share in record.shares
            ],
        }

    def snapshot(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        members, labels = self._members(actor)
        exported = self.store.export(
            actor, core_id=core_id, home_id=home_id, members=members
        )
        return {
            "authority": self._authority(actor, members),
            "ledgerRevision": exported["ledgerRevision"],
            "participants": [
                {"id": identifier, "label": labels[identifier]}
                for identifier in members.ids
            ],
            "records": exported["expenses"],
        }

    def create(self, actor, core_id, home_id, body):
        self._scope(core_id, home_id)
        members, _labels = self._members(actor, write=True)
        if body.expectedMembersRevision != members.revision:
            raise ApiError("authority_changed", 409)
        receipt = self.store.create(
            actor,
            core_id=core_id,
            home_id=home_id,
            expected_ledger_revision=body.expectedLedgerRevision,
            command_id=body.commandId,
            title=body.title,
            currency=body.currency,
            total_minor=body.totalMinor,
            payer_id=body.payerId,
            participant_ids=tuple(body.participantIds),
            members=members,
        )
        return self._receipt(actor, members, receipt)

    def receipt(self, actor, core_id, home_id, command_id):
        self._scope(core_id, home_id)
        members, _labels = self._members(actor)
        receipt = self.store.receipt(
            actor,
            command_id,
            core_id=core_id,
            home_id=home_id,
            members=members,
        )
        return None if receipt is None else self._receipt(actor, members, receipt)

    def export(self, actor, core_id, home_id, body):
        self._scope(core_id, home_id)
        members, _labels = self._members(actor)
        value = self.store.export(
            actor, core_id=core_id, home_id=home_id, members=members
        )
        if value["ledgerRevision"] != body.expectedLedgerRevision:
            raise ApiError("revision_conflict", 409)
        return {
            "authority": self._authority(actor, members),
            "ledgerRevision": value["ledgerRevision"],
            "records": value["expenses"],
        }

    def _receipt(self, actor, members, receipt):
        return {
            "authority": self._authority(actor, members),
            "eventId": receipt.event_id,
            "commandId": receipt.command_id,
            "ledgerRevision": receipt.ledger_revision,
            "record": self._record(receipt.expense),
        }
