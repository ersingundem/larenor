from dataclasses import asdict, dataclass
import hashlib
import hmac
import json
import sqlite3
import time
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..auth import Principal
from ..database import Database
from ..errors import ApiError, StartupError


CURRENCY_SCALES = {"EUR": 2, "GBP": 2, "JPY": 0, "TRY": 2, "USD": 2}
MAX_ACCOUNTS = 32
MAX_EXPENSES = 1000
MAX_TITLE_LENGTH = 200
MAX_TOTAL_MINOR = 10**12


def _identifier(value: str) -> bool:
    return (
        isinstance(value, str)
        and 1 <= len(value) <= 128
        and all(character.isalnum() or character in "-_.:" for character in value)
    )


@dataclass(frozen=True)
class HouseholdAccounts:
    revision: int
    ids: tuple[str, ...]

    def __post_init__(self) -> None:
        if (
            type(self.revision) is not int
            or self.revision < 1
            or not isinstance(self.ids, tuple)
            or not 1 <= len(self.ids) <= MAX_ACCOUNTS
            or len(set(self.ids)) != len(self.ids)
            or any(not _identifier(identifier) for identifier in self.ids)
        ):
            raise ValueError("invalid_household_accounts")


@dataclass(frozen=True)
class ExpenseShare:
    account_id: str
    amount_minor: int


@dataclass(frozen=True)
class ExpenseRecord:
    id: str
    revision: int
    title: str
    currency: str
    currency_scale: int
    total_minor: int
    payer_id: str
    shares: tuple[ExpenseShare, ...]
    members_revision: int
    created_at: float


@dataclass(frozen=True)
class ExpenseReceipt:
    event_id: str
    command_id: str
    ledger_revision: int
    expense: ExpenseRecord


@dataclass(frozen=True)
class ExpenseEvent:
    event_id: str
    action: str
    actor_id: str
    record_id: str
    ledger_revision: int
    occurred_at: float


class ExpenseStore:
    """No-float expense ledger; it never stores bank or payment credentials."""

    def __init__(
        self,
        database: Database,
        *,
        encryption_key: bytes,
        audit_key: bytes,
    ):
        if (
            not isinstance(encryption_key, bytes)
            or len(encryption_key) != 32
            or not isinstance(audit_key, bytes)
            or len(audit_key) != 32
        ):
            raise ValueError("invalid_expense_keys")
        self.database = database
        self._cipher = AESGCM(encryption_key)
        self._audit_key = audit_key

    @staticmethod
    def _scope(core_id: str, home_id: str) -> None:
        if not _identifier(core_id) or not _identifier(home_id):
            raise ApiError("invalid_request", 400)

    @staticmethod
    def _canonical(value: object) -> bytes:
        return json.dumps(
            value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode()

    def _state_hash(
        self,
        core_id: str,
        home_id: str,
        revision: int,
        event_count: int,
        last_hash: str,
    ) -> str:
        return hmac.new(
            self._audit_key,
            b"larenor-shared-expense-state-v1\0"
            + self._canonical([core_id, home_id, revision, event_count, last_hash]),
            hashlib.sha256,
        ).hexdigest()

    def _event_hash(self, values: tuple[object, ...]) -> str:
        return hmac.new(
            self._audit_key,
            b"larenor-shared-expense-event-v1\0" + self._canonical(values),
            hashlib.sha256,
        ).hexdigest()

    def _state(
        self,
        connection: sqlite3.Connection,
        core_id: str,
        home_id: str,
    ) -> sqlite3.Row | None:
        row = connection.execute(
            "SELECT * FROM shared_expense_state WHERE core_id=? AND home_id=?",
            (core_id, home_id),
        ).fetchone()
        if row is not None and not hmac.compare_digest(
            row["state_hash"],
            self._state_hash(
                core_id, home_id, row["revision"], row["event_count"], row["last_hash"]
            ),
        ):
            raise StartupError("shared_expense_history_invalid")
        return row

    @staticmethod
    def _authorize(actor: Principal, members: HouseholdAccounts) -> None:
        if actor.role != "admin" and actor.id not in members.ids:
            raise ApiError("forbidden", 403)

    def _request(
        self,
        *,
        expected_ledger_revision: int,
        title: str,
        currency: str,
        total_minor: int,
        payer_id: str,
        participant_ids: tuple[str, ...],
        members: HouseholdAccounts,
    ) -> tuple[dict, str]:
        if (
            type(expected_ledger_revision) is not int
            or expected_ledger_revision < 1
            or not isinstance(title, str)
            or not 1 <= len(title.strip()) <= MAX_TITLE_LENGTH
            or currency not in CURRENCY_SCALES
            or type(total_minor) is not int
            or not 1 <= total_minor <= MAX_TOTAL_MINOR
            or not _identifier(payer_id)
            or not isinstance(participant_ids, tuple)
            or not 1 <= len(participant_ids) <= MAX_ACCOUNTS
            or len(set(participant_ids)) != len(participant_ids)
            or any(identifier not in members.ids for identifier in participant_ids)
            or payer_id not in members.ids
        ):
            raise ApiError("invalid_request", 400)
        participants = tuple(sorted(participant_ids))
        base, remainder = divmod(total_minor, len(participants))
        shares = [
            {"account_id": identifier, "amount_minor": base + (index < remainder)}
            for index, identifier in enumerate(participants)
        ]
        value = {
            "expected_ledger_revision": expected_ledger_revision,
            "title": title.strip(),
            "currency": currency,
            "currency_scale": CURRENCY_SCALES[currency],
            "total_minor": total_minor,
            "payer_id": payer_id,
            "shares": shares,
            "members_revision": members.revision,
        }
        return value, hashlib.sha256(self._canonical(value)).hexdigest()

    def _decrypt(self, row: sqlite3.Row) -> ExpenseRecord:
        try:
            aad = f"{row['core_id']}\0{row['home_id']}\0{row['id']}".encode()
            raw = self._cipher.decrypt(row["nonce"], row["ciphertext"], aad)
            if hashlib.sha256(raw).hexdigest() != row["payload_hash"]:
                raise ValueError
            value = json.loads(raw)
            shares = tuple(ExpenseShare(**share) for share in value.pop("shares"))
            record = ExpenseRecord(
                id=row["id"], revision=row["revision"], shares=shares, **value
            )
            if sum(share.amount_minor for share in shares) != record.total_minor:
                raise ValueError
            return record
        except (InvalidTag, KeyError, TypeError, ValueError, json.JSONDecodeError):
            raise StartupError("shared_expense_storage_invalid") from None

    def _record(
        self,
        connection: sqlite3.Connection,
        record_id: str,
    ) -> ExpenseRecord:
        row = connection.execute(
            "SELECT * FROM shared_expense_records WHERE id=?", (record_id,)
        ).fetchone()
        if row is None:
            raise StartupError("shared_expense_history_invalid")
        return self._decrypt(row)

    def _verified_history(
        self,
        connection: sqlite3.Connection,
        core_id: str,
        home_id: str,
    ) -> tuple[ExpenseEvent, ...]:
        state = self._state(connection, core_id, home_id)
        rows = connection.execute(
            "SELECT * FROM shared_expense_events WHERE core_id=? AND home_id=? ORDER BY sequence",
            (core_id, home_id),
        ).fetchall()
        if state is None:
            if rows:
                raise StartupError("shared_expense_history_invalid")
            return ()
        previous = ""
        events: list[ExpenseEvent] = []
        seen: set[str] = set()
        for row in rows:
            values = (
                row["sequence"],
                row["event_id"],
                row["core_id"],
                row["home_id"],
                row["command_id"],
                row["action"],
                row["actor_id"],
                row["record_id"],
                row["ledger_revision"],
                row["occurred_at"],
                row["request_hash"],
                row["previous_hash"],
            )
            if row["previous_hash"] != previous or not hmac.compare_digest(
                row["event_hash"], self._event_hash(values)
            ):
                raise StartupError("shared_expense_history_invalid")
            record = self._record(connection, row["record_id"])
            request_value = {
                "expected_ledger_revision": row["ledger_revision"] - 1,
                "title": record.title,
                "currency": record.currency,
                "currency_scale": record.currency_scale,
                "total_minor": record.total_minor,
                "payer_id": record.payer_id,
                "shares": [asdict(share) for share in record.shares],
                "members_revision": record.members_revision,
            }
            if (
                hashlib.sha256(self._canonical(request_value)).hexdigest()
                != row["request_hash"]
            ):
                raise StartupError("shared_expense_history_invalid")
            seen.add(row["record_id"])
            events.append(
                ExpenseEvent(
                    row["event_id"],
                    row["action"],
                    row["actor_id"],
                    row["record_id"],
                    row["ledger_revision"],
                    row["occurred_at"],
                )
            )
            previous = row["event_hash"]
        record_count = connection.execute(
            "SELECT COUNT(*) FROM shared_expense_records WHERE core_id=? AND home_id=?",
            (core_id, home_id),
        ).fetchone()[0]
        if (
            len(rows) != state["event_count"]
            or state["revision"] != len(rows) + 1
            or state["last_hash"] != previous
            or record_count != len(seen)
        ):
            raise StartupError("shared_expense_history_invalid")
        return tuple(events)

    def create(
        self,
        actor: Principal,
        *,
        core_id: str,
        home_id: str,
        expected_ledger_revision: int,
        command_id: str,
        title: str,
        currency: str,
        total_minor: int,
        payer_id: str,
        participant_ids: tuple[str, ...],
        members: HouseholdAccounts,
    ) -> ExpenseReceipt:
        self._scope(core_id, home_id)
        self._authorize(actor, members)
        if not _identifier(command_id):
            raise ApiError("invalid_request", 400)
        if actor.role != "admin" and actor.id != payer_id:
            raise ApiError("forbidden", 403)
        request, request_hash = self._request(
            expected_ledger_revision=expected_ledger_revision,
            title=title,
            currency=currency,
            total_minor=total_minor,
            payer_id=payer_id,
            participant_ids=participant_ids,
            members=members,
        )
        with self.database.transaction() as connection:
            self._verified_history(connection, core_id, home_id)
            replay = connection.execute(
                "SELECT * FROM shared_expense_events WHERE core_id=? AND home_id=? AND command_id=?",
                (core_id, home_id, command_id),
            ).fetchone()
            if replay is not None:
                if (
                    replay["actor_id"] != actor.id
                    or replay["request_hash"] != request_hash
                ):
                    raise ApiError("idempotency_conflict", 409)
                return ExpenseReceipt(
                    replay["event_id"],
                    command_id,
                    replay["ledger_revision"],
                    self._record(connection, replay["record_id"]),
                )
            state = self._state(connection, core_id, home_id)
            current_revision = 1 if state is None else state["revision"]
            if expected_ledger_revision != current_revision:
                raise ApiError("revision_conflict", 409)
            count = 0 if state is None else state["event_count"]
            if count >= MAX_EXPENSES:
                raise ApiError("shared_expense_limit_reached", 413)
            now = time.time()
            record_id, event_id = uuid.uuid4().hex, uuid.uuid4().hex
            record_value = {
                key: value
                for key, value in request.items()
                if key != "expected_ledger_revision"
            }
            record_value["created_at"] = now
            raw = self._canonical(record_value)
            nonce = uuid.uuid4().bytes[:12]
            aad = f"{core_id}\0{home_id}\0{record_id}".encode()
            connection.execute(
                "INSERT INTO shared_expense_records VALUES(?,?,?,?,?,?,?,?)",
                (
                    record_id,
                    core_id,
                    home_id,
                    1,
                    nonce,
                    self._cipher.encrypt(nonce, raw, aad),
                    hashlib.sha256(raw).hexdigest(),
                    now,
                ),
            )
            sequence = connection.execute(
                "SELECT COALESCE(MAX(sequence),0)+1 FROM shared_expense_events"
            ).fetchone()[0]
            ledger_revision = current_revision + 1
            previous = "" if state is None else state["last_hash"]
            event_values = (
                sequence,
                event_id,
                core_id,
                home_id,
                command_id,
                "created",
                actor.id,
                record_id,
                ledger_revision,
                now,
                request_hash,
                previous,
            )
            event_hash = self._event_hash(event_values)
            connection.execute(
                "INSERT INTO shared_expense_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (*event_values, event_hash),
            )
            state_hash = self._state_hash(
                core_id, home_id, ledger_revision, count + 1, event_hash
            )
            connection.execute(
                "INSERT INTO shared_expense_state VALUES(?,?,?,?,?,?) "
                "ON CONFLICT(core_id,home_id) DO UPDATE SET revision=excluded.revision,"
                "event_count=excluded.event_count,last_hash=excluded.last_hash,"
                "state_hash=excluded.state_hash",
                (core_id, home_id, ledger_revision, count + 1, event_hash, state_hash),
            )
            record = self._record(connection, record_id)
        return ExpenseReceipt(event_id, command_id, ledger_revision, record)

    def history(
        self,
        actor: Principal,
        *,
        core_id: str,
        home_id: str,
        members: HouseholdAccounts,
    ) -> tuple[ExpenseEvent, ...]:
        self._scope(core_id, home_id)
        self._authorize(actor, members)
        with self.database.connection() as connection:
            return self._verified_history(connection, core_id, home_id)

    def export(
        self,
        actor: Principal,
        *,
        core_id: str,
        home_id: str,
        members: HouseholdAccounts,
    ) -> dict:
        self._scope(core_id, home_id)
        self._authorize(actor, members)
        with self.database.connection() as connection:
            self._verified_history(connection, core_id, home_id)
            state = self._state(connection, core_id, home_id)
            rows = connection.execute(
                "SELECT * FROM shared_expense_records WHERE core_id=? AND home_id=? "
                "ORDER BY created_at,id LIMIT ?",
                (core_id, home_id, MAX_EXPENSES + 1),
            ).fetchall()
            if len(rows) > MAX_EXPENSES:
                raise StartupError("shared_expense_storage_invalid")
            records = [self._decrypt(row) for row in rows]
        visible = [
            record
            for record in records
            if actor.role == "admin"
            or actor.id == record.payer_id
            or any(share.account_id == actor.id for share in record.shares)
        ]
        return {
            "schemaVersion": 1,
            "coreId": core_id,
            "homeId": home_id,
            "ledgerRevision": 1 if state is None else state["revision"],
            "expenses": [
                {
                    "id": record.id,
                    "revision": record.revision,
                    "title": record.title,
                    "currency": record.currency,
                    "currencyScale": record.currency_scale,
                    "totalMinor": record.total_minor,
                    "payerId": record.payer_id,
                    "shares": [
                        {
                            "accountId": share.account_id,
                            "amountMinor": share.amount_minor,
                        }
                        for share in record.shares
                    ],
                    "createdAt": record.created_at,
                }
                for record in visible
            ],
        }
