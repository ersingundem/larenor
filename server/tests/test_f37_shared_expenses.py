from pathlib import Path

import pytest

from larenor_server.auth import Principal
from larenor_server.database import Database
from larenor_server.errors import ApiError, StartupError
from larenor_server.shared_expenses.schema import migrate_shared_expenses
from larenor_server.shared_expenses.service import (
    ExpenseStore,
    HouseholdAccounts,
)


ENCRYPTION_KEY = bytes.fromhex("31" * 32)
AUDIT_KEY = bytes.fromhex("73" * 32)


def actor(identifier: str, role: str = "member") -> Principal:
    return Principal(identifier, identifier, role, False, "family", "token")


def store(path: Path) -> ExpenseStore:
    database = Database(path)
    if not path.exists():
        database.create_schema()
    with database.transaction() as connection:
        migrate_shared_expenses(connection)
    return ExpenseStore(
        database,
        encryption_key=ENCRYPTION_KEY,
        audit_key=AUDIT_KEY,
    )


def test_integer_currency_split_is_deterministic_and_conserves_every_unit(tmp_path):
    expenses = store(tmp_path / "core.sqlite3")
    members = HouseholdAccounts(8, ("cem", "ada", "baran"))
    receipt = expenses.create(
        actor("cem"),
        core_id="core-a",
        home_id="home-a",
        expected_ledger_revision=1,
        command_id="expense-1",
        title="Ortak market",
        currency="JPY",
        total_minor=100,
        payer_id="cem",
        participant_ids=("cem", "ada", "baran"),
        members=members,
    )

    assert receipt.ledger_revision == 2
    assert receipt.expense.currency_scale == 0
    assert [
        (share.account_id, share.amount_minor) for share in receipt.expense.shares
    ] == [
        ("ada", 34),
        ("baran", 33),
        ("cem", 33),
    ]
    assert sum(share.amount_minor for share in receipt.expense.shares) == 100

    with pytest.raises(ApiError, match="invalid_request"):
        expenses.create(
            actor("cem"),
            core_id="core-a",
            home_id="home-a",
            expected_ledger_revision=2,
            command_id="expense-float",
            title="Bad",
            currency="TRY",
            total_minor=10.5,
            payer_id="cem",
            participant_ids=("cem",),
            members=members,
        )


def test_scope_revision_membership_and_idempotency_fail_closed(tmp_path):
    expenses = store(tmp_path / "core.sqlite3")
    members = HouseholdAccounts(3, ("ada", "baran"))
    request = dict(
        core_id="core-a",
        home_id="home-a",
        expected_ledger_revision=1,
        command_id="expense-1",
        title="İnternet",
        currency="TRY",
        total_minor=45000,
        payer_id="ada",
        participant_ids=("ada", "baran"),
        members=members,
    )
    first = expenses.create(actor("ada"), **request)
    assert expenses.create(actor("ada"), **request) == first
    assert (
        len(
            expenses.history(
                actor("ada"), core_id="core-a", home_id="home-a", members=members
            )
        )
        == 1
    )

    with pytest.raises(ApiError, match="idempotency_conflict"):
        expenses.create(actor("ada"), **{**request, "total_minor": 45001})
    with pytest.raises(ApiError, match="revision_conflict"):
        expenses.create(actor("ada"), **{**request, "command_id": "expense-2"})
    with pytest.raises(ApiError, match="forbidden"):
        expenses.create(
            actor("mallory"),
            **{**request, "command_id": "expense-3", "expected_ledger_revision": 2},
        )
    with pytest.raises(ApiError, match="forbidden"):
        expenses.export(
            actor("mallory"), core_id="core-a", home_id="home-a", members=members
        )
    assert (
        expenses.export(
            actor("ada"), core_id="core-a", home_id="home-b", members=members
        )["expenses"]
        == []
    )


def test_authorized_export_is_bounded_secret_free_and_history_detects_tamper(tmp_path):
    path = tmp_path / "core.sqlite3"
    expenses = store(path)
    members = HouseholdAccounts(5, ("ada", "baran", "cem"))
    first = expenses.create(
        actor("ada"),
        core_id="core-a",
        home_id="home-a",
        expected_ledger_revision=1,
        command_id="expense-1",
        title="Elektrik",
        currency="TRY",
        total_minor=9000,
        payer_id="ada",
        participant_ids=("ada", "baran"),
        members=members,
    )
    expenses.create(
        actor("cem"),
        core_id="core-a",
        home_id="home-a",
        expected_ledger_revision=2,
        command_id="expense-2",
        title="Atölye",
        currency="EUR",
        total_minor=3000,
        payer_id="cem",
        participant_ids=("cem",),
        members=members,
    )

    member_export = expenses.export(
        actor("baran"), core_id="core-a", home_id="home-a", members=members
    )
    assert [item["title"] for item in member_export["expenses"]] == ["Elektrik"]
    admin_export = expenses.export(
        actor("admin", "admin"), core_id="core-a", home_id="home-a", members=members
    )
    assert [item["title"] for item in admin_export["expenses"]] == [
        "Elektrik",
        "Atölye",
    ]
    assert set(admin_export) == {
        "schemaVersion",
        "coreId",
        "homeId",
        "ledgerRevision",
        "expenses",
    }
    assert not any(
        "bank" in key.lower() or "payment" in key.lower()
        for item in admin_export["expenses"]
        for key in item
    )

    with Database(path).connection() as connection:
        ciphertext = connection.execute(
            "SELECT ciphertext FROM shared_expense_records WHERE id=?",
            (first.expense.id,),
        ).fetchone()[0]
    assert b"Elektrik" not in ciphertext

    with Database(path).transaction() as connection:
        connection.execute(
            "UPDATE shared_expense_events SET actor_id='mallory' WHERE sequence=1"
        )
    with pytest.raises(StartupError, match="shared_expense_history_invalid"):
        store(path).export(
            actor("admin", "admin"), core_id="core-a", home_id="home-a", members=members
        )
