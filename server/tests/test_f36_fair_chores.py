from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

from larenor_server.auth import Principal
from larenor_server.database import Database
from larenor_server.errors import ApiError, StartupError
from larenor_server.fair_chores.schema import migrate_fair_chores
from larenor_server.fair_chores.service import (
    FairChoreStore,
    HouseholdMembers,
)


AUDIT_KEY = bytes.fromhex("42" * 32)


def principal(identifier: str, role: str = "member") -> Principal:
    return Principal(identifier, identifier, role, False, "family", "token")


def store(path: Path) -> FairChoreStore:
    database = Database(path)
    if not path.exists():
        database.create_schema()
    with database.transaction() as connection:
        migrate_fair_chores(connection)
    return FairChoreStore(database, audit_key=AUDIT_KEY)


def test_completion_rotates_current_members_and_repeats_from_real_local_completion(
    tmp_path,
):
    chores = store(tmp_path / "core.sqlite3")
    members = HouseholdMembers(7, ("ada", "baran", "cem"))
    due = datetime(2026, 3, 28, 11, tzinfo=ZoneInfo("Europe/Berlin"))
    task = chores.create(
        principal("admin", "admin"),
        core_id="core-a",
        home_id="home-a",
        title="Mutfağı temizle",
        members=members,
        timezone_name="Europe/Berlin",
        interval_days=1,
        due_at=due.timestamp(),
    )
    assert task.assignee_id == "ada"

    completed_at = datetime(2026, 3, 28, 11, tzinfo=timezone.utc).timestamp()
    receipt = chores.complete(
        principal("ada"),
        task.id,
        core_id="core-a",
        home_id="home-a",
        expected_revision=1,
        command_id="complete-1",
        completed_at=completed_at,
        members=members,
    )
    local_due = datetime.fromtimestamp(receipt.task.due_at, ZoneInfo("Europe/Berlin"))
    assert (receipt.task.assignee_id, receipt.task.revision) == ("baran", 2)
    assert (local_due.date().isoformat(), local_due.hour) == ("2026-03-29", 12)

    restored = store(tmp_path / "core.sqlite3").get(
        principal("baran"), task.id, core_id="core-a", home_id="home-a"
    )
    assert restored == receipt.task


def test_authority_revision_and_departed_member_fail_closed(tmp_path):
    chores = store(tmp_path / "core.sqlite3")
    original = HouseholdMembers(4, ("ada", "baran", "cem"))
    task = chores.create(
        principal("admin", "admin"),
        core_id="core-a",
        home_id="home-a",
        title="Çamaşırları katla",
        members=original,
        timezone_name="Europe/Istanbul",
        interval_days=7,
        due_at=1_800_000_000,
    )

    with pytest.raises(ApiError, match="not_found"):
        chores.get(principal("ada"), task.id, core_id="core-a", home_id="home-b")
    with pytest.raises(ApiError, match="forbidden"):
        chores.defer(
            principal("baran"), task.id, core_id="core-a", home_id="home-a",
            expected_revision=1, command_id="defer-foreign", days=1,
        )
    with pytest.raises(ApiError, match="revision_conflict"):
        chores.complete(
            principal("ada"), task.id, core_id="core-a", home_id="home-a",
            expected_revision=9, command_id="complete-stale", completed_at=1_800_000_100,
            members=original,
        )

    current = HouseholdMembers(5, ("ada", "cem"))
    receipt = chores.complete(
        principal("ada"), task.id, core_id="core-a", home_id="home-a",
        expected_revision=1, command_id="complete-current", completed_at=1_800_000_100,
        members=current,
    )
    assert receipt.task.assignee_id == "cem"
    assert receipt.task.members_revision == 5


def test_completion_is_idempotent_and_history_detects_restart_tamper(tmp_path):
    path = tmp_path / "core.sqlite3"
    chores = store(path)
    members = HouseholdMembers(1, ("ada", "baran"))
    task = chores.create(
        principal("admin", "admin"),
        core_id="core-a", home_id="home-a", title="Bitkileri sula",
        members=members, timezone_name="Europe/Istanbul", interval_days=2,
        due_at=1_800_000_000,
    )
    first = chores.complete(
        principal("ada"), task.id, core_id="core-a", home_id="home-a",
        expected_revision=1, command_id="complete-once", completed_at=1_800_000_100,
        members=members,
    )
    replay = chores.complete(
        principal("ada"), task.id, core_id="core-a", home_id="home-a",
        expected_revision=1, command_id="complete-once", completed_at=1_800_000_100,
        members=members,
    )
    assert replay == first
    assert [event.action for event in chores.history(
        principal("ada"), task.id, core_id="core-a", home_id="home-a"
    )] == ["created", "completed"]

    with Database(path).transaction() as connection:
        connection.execute(
            "UPDATE fair_chore_events SET actor_id='mallory' WHERE action='completed'"
        )
    with pytest.raises(StartupError, match="fair_chore_history_invalid"):
        store(path).history(
            principal("ada"), task.id, core_id="core-a", home_id="home-a"
        )
