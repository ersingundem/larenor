import json
from pathlib import Path

import pytest

from larenor_server.auth import Principal
from larenor_server.database import Database
from larenor_server.errors import ApiError, StartupError
from larenor_server.resource_reservations.schema import migrate_resource_reservations
from larenor_server.resource_reservations.service import (
    ReservationAuthority,
    ReservationStore,
    ResourceRule,
)


ENCRYPTION_KEY = bytes.fromhex("40" * 32)
AUDIT_KEY = bytes.fromhex("04" * 32)


def actor(identifier: str, role: str = "member") -> Principal:
    return Principal(identifier, identifier, role, False, "family", "token")


def store(path: Path) -> ReservationStore:
    database = Database(path)
    if not path.exists():
        database.create_schema()
    with database.transaction() as connection:
        migrate_resource_reservations(connection)
    return ReservationStore(
        database,
        encryption_key=ENCRYPTION_KEY,
        audit_key=AUDIT_KEY,
    )


def authority(*, calendar_revision: int = 7, capacity: int = 1) -> ReservationAuthority:
    return ReservationAuthority(
        core_id="core-a",
        home_id="home-a",
        account_id="ada",
        core_revision=3,
        home_revision=5,
        account_revision=9,
        members_revision=11,
        calendar_revision=calendar_revision,
        member_ids=("ada", "baran"),
        resource=ResourceRule(
            id="room-study",
            revision=13,
            capacity=capacity,
            timezone="Europe/Berlin",
            member_ids=("ada", "baran"),
        ),
    )


def create_bytes(
    *,
    command_id: str,
    local_start: str,
    expected_calendar_revision: int = 7,
    fold: int | None = 0,
    count: int = 1,
    units: int = 1,
) -> bytes:
    value = {
        "action": "create",
        "commandId": command_id,
        "coreId": "core-a",
        "homeId": "home-a",
        "accountId": "ada",
        "coreRevision": 3,
        "homeRevision": 5,
        "accountRevision": 9,
        "membersRevision": 11,
        "resourceId": "room-study",
        "resourceRevision": 13,
        "expectedCalendarRevision": expected_calendar_revision,
        "timezone": "Europe/Berlin",
        "localStart": local_start,
        "fold": fold,
        "durationSeconds": 3600,
        "units": units,
        "recurrence": {"frequency": "weekly", "count": count},
    }
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def cancel_bytes(
    *, command_id: str, reservation_id: str, revision: int, account_id: str = "ada"
) -> bytes:
    return json.dumps(
        {
            "action": "cancel",
            "commandId": command_id,
            "coreId": "core-a",
            "homeId": "home-a",
            "accountId": account_id,
            "coreRevision": 3,
            "homeRevision": 5,
            "accountRevision": 9,
            "membersRevision": 11,
            "resourceId": "room-study",
            "resourceRevision": 13,
            "expectedCalendarRevision": revision,
            "reservationId": reservation_id,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()


def test_timezone_recurrence_dst_and_capacity_overlap_are_deterministic(tmp_path):
    reservations = store(tmp_path / "core.sqlite3")
    scope = authority(capacity=2)
    first = reservations.create(
        actor("ada"),
        command_bytes=create_bytes(
            command_id="reserve-1",
            local_start="2026-10-25T02:30:00",
            fold=0,
            units=2,
        ),
        authority=scope,
    )
    assert first.calendar_revision == 8
    assert first.reservation.occurrences[0].start_utc == "2026-10-25T00:30:00Z"

    later_fold = create_bytes(
        command_id="reserve-2",
        local_start="2026-10-25T02:30:00",
        expected_calendar_revision=8,
        fold=1,
    )
    second = reservations.create(
        actor("ada"), command_bytes=later_fold,
        authority=authority(calendar_revision=8, capacity=2),
    )
    assert second.reservation.occurrences[0].start_utc == "2026-10-25T01:30:00Z"

    with pytest.raises(ApiError, match="reservation_overlap"):
        reservations.create(
            actor("ada"),
            command_bytes=create_bytes(
                command_id="reserve-3",
                local_start="2026-10-25T02:45:00",
                expected_calendar_revision=9,
                fold=1,
                units=2,
            ),
            authority=authority(calendar_revision=9, capacity=2),
        )
    with pytest.raises(ApiError, match="invalid_local_time"):
        reservations.create(
            actor("ada"),
            command_bytes=create_bytes(
                command_id="spring-gap",
                local_start="2026-03-29T02:30:00",
                expected_calendar_revision=9,
                fold=None,
            ),
            authority=authority(calendar_revision=9, capacity=2),
        )

    capacity_store = store(tmp_path / "capacity.sqlite3")
    capacity_store.create(
        actor("ada"),
        command_bytes=create_bytes(
            command_id="capacity-1", local_start="2026-11-01T10:00:00"
        ),
        authority=authority(capacity=3),
    )
    capacity_store.create(
        actor("ada"),
        command_bytes=create_bytes(
            command_id="capacity-2", local_start="2026-11-01T10:00:00",
            expected_calendar_revision=8,
        ),
        authority=authority(calendar_revision=8, capacity=3),
    )
    with pytest.raises(ApiError, match="reservation_overlap"):
        capacity_store.create(
            actor("ada"),
            command_bytes=create_bytes(
                command_id="capacity-3", local_start="2026-11-01T10:00:00",
                expected_calendar_revision=9, units=2,
            ),
            authority=authority(calendar_revision=9, capacity=3),
        )


def test_exact_authority_idempotency_conflict_cancel_and_audit(tmp_path):
    path = tmp_path / "core.sqlite3"
    reservations = store(path)
    command = create_bytes(command_id="reserve-1", local_start="2026-11-01T10:00:00")
    first = reservations.create(actor("ada"), command_bytes=command, authority=authority())
    assert reservations.create(actor("ada"), command_bytes=command, authority=authority()) == first

    semantically_equal_different_bytes = json.dumps(json.loads(command), indent=2).encode()
    with pytest.raises(ApiError, match="idempotency_conflict"):
        reservations.create(
            actor("ada"),
            command_bytes=semantically_equal_different_bytes,
            authority=authority(),
        )
    with pytest.raises(ApiError, match="authority_changed"):
        reservations.create(
            actor("ada"),
            command_bytes=create_bytes(
                command_id="reserve-stale",
                local_start="2026-11-02T10:00:00",
                expected_calendar_revision=8,
            ).replace(b'"accountRevision":9', b'"accountRevision":8'),
            authority=authority(calendar_revision=8),
        )

    denied_cancel = cancel_bytes(
        command_id="cancel-denied",
        reservation_id=first.reservation.id,
        revision=8,
        account_id="baran",
    )
    baran_authority = ReservationAuthority(
        **{**authority(calendar_revision=8).__dict__, "account_id": "baran"}
    )
    with pytest.raises(ApiError, match="forbidden"):
        reservations.cancel(
            actor("baran"), command_bytes=denied_cancel, authority=baran_authority
        )

    cancel = cancel_bytes(
        command_id="cancel-1",
        reservation_id=first.reservation.id,
        revision=8,
        account_id="admin",
    )
    admin_authority = ReservationAuthority(
        **{**authority(calendar_revision=8).__dict__, "account_id": "admin"}
    )
    cancelled = reservations.cancel(
        actor("admin", "admin"), command_bytes=cancel, authority=admin_authority
    )
    assert cancelled.calendar_revision == 9
    assert reservations.cancel(
        actor("admin", "admin"), command_bytes=cancel, authority=admin_authority
    ) == cancelled

    with Database(path).transaction() as connection:
        connection.execute(
            "UPDATE resource_reservation_events SET actor_id='mallory' WHERE action='created'"
        )
    with pytest.raises(StartupError, match="resource_reservation_history_invalid"):
        store(path).history(
            actor("ada"), authority=authority(calendar_revision=9), limit=20
        )


def test_encrypted_role_scoped_bounded_availability_and_export(tmp_path):
    path = tmp_path / "core.sqlite3"
    reservations = store(path)
    created = reservations.create(
        actor("ada"),
        command_bytes=create_bytes(
            command_id="reserve-private",
            local_start="2026-12-06T10:00:00",
            count=2,
        ),
        authority=authority(),
    )
    with Database(path).connection() as connection:
        row = connection.execute(
            "SELECT ciphertext FROM resource_reservations WHERE id=?",
            (created.reservation.id,),
        ).fetchone()
    assert b"2026-12-06" not in row["ciphertext"]
    assert b"ada" not in row["ciphertext"]

    availability = reservations.availability(
        actor("baran"),
        authority=ReservationAuthority(
            **{**authority(calendar_revision=8).__dict__, "account_id": "baran"}
        ),
        start_utc="2026-12-01T00:00:00Z",
        end_utc="2026-12-31T00:00:00Z",
        limit=16,
    )
    assert availability["calendarRevision"] == 8
    assert len(availability["busy"]) == 2
    assert all(set(item) == {"startUtc", "endUtc", "units"} for item in availability["busy"])

    exported = reservations.export(
        actor("ada"), authority=authority(calendar_revision=8), limit=16
    )
    assert set(exported) == {
        "schemaVersion", "coreId", "homeId", "resourceId",
        "calendarRevision", "reservations",
    }
    assert all(
        not any(word in key.lower() for word in ("command", "hash", "nonce", "cipher", "key"))
        for item in exported["reservations"]
        for key in item
    )
    with pytest.raises(ApiError, match="forbidden"):
        reservations.availability(
            actor("mallory"),
            authority=ReservationAuthority(
                **{**authority(calendar_revision=8).__dict__, "account_id": "mallory"}
            ),
            start_utc="2026-12-01T00:00:00Z",
            end_utc="2026-12-31T00:00:00Z",
            limit=16,
        )
    with pytest.raises(ApiError, match="invalid_request"):
        reservations.availability(
            actor("ada"), authority=authority(calendar_revision=8),
            start_utc="2026-01-01T00:00:00Z",
            end_utc="2027-01-01T00:00:00Z",
            limit=16,
        )
