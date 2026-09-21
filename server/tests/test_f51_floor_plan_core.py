from dataclasses import replace
from pathlib import Path

import pytest

from larenor_server.auth import Principal
from larenor_server.database import Database
from larenor_server.errors import ApiError, StartupError
from larenor_server.floor_plan.schema import migrate_floor_plan
from larenor_server.floor_plan.service import (
    Anchor,
    EntitySnapshot,
    Floor,
    FloorPlanAuthority,
    FloorPlanLayout,
    FloorPlanService,
    Point,
    Room,
    VectorShape,
)


AUDIT_KEY = bytes.fromhex("51" * 32)
NOW = 1_800_000_000.0


def actor(account_id: str = "ada", session_id: str = "session-a") -> Principal:
    return Principal(account_id, account_id, "member", False, session_id, "token")


def authority(
    *, home_id: str = "home-a", layout_revision: int = 0,
    can_read: bool = True, can_edit: bool = True,
) -> FloorPlanAuthority:
    return FloorPlanAuthority(
        core_id="core-a",
        home_id=home_id,
        account_id="ada",
        session_id="session-a",
        core_revision=3,
        home_revision=5,
        account_revision=7,
        layout_revision=layout_revision,
        entity_registry_revision=11,
        resource_revision=13,
        grant_revision=17,
        can_read=can_read,
        can_edit=can_edit,
    )


def layout(*, label: str = "Ground floor") -> FloorPlanLayout:
    return FloorPlanLayout(
        floors=(Floor("floor-ground", label, 0),),
        rooms=(Room(
            "room-living", "floor-ground", "Living room",
            (Point(0.05, 0.05), Point(0.95, 0.05), Point(0.95, 0.95)),
        ),),
        anchors=(
            Anchor(
                "anchor-light", "room-living", "entity", "light.living", 23,
                0.35, 0.40, 0,
            ),
            Anchor(
                "anchor-tv", "room-living", "resource", "media-tv", 29,
                0.65, 0.40, 0,
            ),
        ),
        vectors=(VectorShape(
            "wall-north", "floor-ground", "wall",
            (Point(0.05, 0.05), Point(0.95, 0.05)),
        ),),
    )


def service(path: Path) -> FloorPlanService:
    database = Database(path)
    if not path.exists():
        database.create_schema()
    with database.transaction() as connection:
        migrate_floor_plan(connection)
    return FloorPlanService(database, audit_key=AUDIT_KEY, clock=lambda: NOW)


def test_bounded_layout_edit_is_optimistic_idempotent_and_restart_durable(tmp_path):
    path = tmp_path / "core.sqlite3"
    plans = service(path)
    receipt = plans.replace_layout(
        actor(), authority=authority(), request_id="edit-1",
        expected_layout_revision=0, layout=layout(),
    )
    assert receipt.revision == 1
    same = service(path).replace_layout(
        actor(), authority=authority(), request_id="edit-1",
        expected_layout_revision=0, layout=layout(),
    )
    assert same == receipt
    with pytest.raises(ApiError, match="floor_plan_edit_conflict"):
        plans.replace_layout(
            actor(), authority=authority(), request_id="edit-1",
            expected_layout_revision=0, layout=layout(label="Changed"),
        )
    with pytest.raises(ApiError, match="floor_plan_revision_changed"):
        plans.replace_layout(
            actor(), authority=authority(), request_id="edit-2",
            expected_layout_revision=0, layout=layout(label="Changed"),
        )
    malformed = replace(layout(), vectors=(VectorShape(
        "bad", "floor-ground", "wall", (Point(-0.1, 0.2), Point(0.5, 0.5)),
    ),))
    with pytest.raises(ApiError, match="floor_plan_invalid"):
        plans.replace_layout(
            actor(), authority=authority(layout_revision=1), request_id="edit-bad",
            expected_layout_revision=1, layout=malformed,
        )


def test_role_grants_history_isolation_and_secret_free_export_are_fail_closed(tmp_path):
    path = tmp_path / "core.sqlite3"
    plans = service(path)
    plans.replace_layout(
        actor(), authority=authority(), request_id="edit-1",
        expected_layout_revision=0, layout=layout(),
    )
    read_only = authority(layout_revision=1, can_edit=False)
    assert plans.read(actor(), authority=read_only).revision == 1
    with pytest.raises(ApiError, match="forbidden"):
        plans.replace_layout(
            actor(), authority=read_only, request_id="edit-denied",
            expected_layout_revision=1, layout=layout(label="Denied"),
        )
    exported = plans.export(actor(), authority=read_only)
    assert exported["formatVersion"] == 1
    assert exported["layoutRevision"] == 1
    assert "session-a" not in str(exported)
    assert "token" not in str(exported)
    with pytest.raises(ApiError, match="not_found"):
        plans.read(actor(), authority=authority(home_id="home-b"))

    with Database(path).transaction() as connection:
        connection.execute(
            "UPDATE floor_plan_events SET actor_id='mallory' WHERE sequence=1"
        )
    with pytest.raises(StartupError, match="floor_plan_audit_invalid"):
        service(path).history(
            actor(), authority=authority(layout_revision=1), limit=20
        )


def test_entity_projection_is_revision_bound_and_marks_stale_or_missing_state(tmp_path):
    path = tmp_path / "core.sqlite3"
    plans = service(path)
    plans.replace_layout(
        actor(), authority=authority(), request_id="edit-1",
        expected_layout_revision=0, layout=layout(),
    )
    current = authority(layout_revision=1)
    with pytest.raises(ApiError, match="floor_plan_authority_changed"):
        plans.read(actor(), authority=replace(current, resource_revision=14))
    live = plans.project_entities(
        actor(), authority=current, snapshots=(
            EntitySnapshot("light.living", 23, 11, "verified", "on", NOW),
        ),
    )
    assert [(item.entity_id, item.state, item.status) for item in live] == [
        ("light.living", "on", "live")
    ]
    stale = plans.project_entities(
        actor(), authority=current, snapshots=(
            EntitySnapshot("light.living", 23, 11, "verified", "on", NOW - 301),
        ),
    )
    assert stale[0].status == "stale"
    assert plans.project_entities(actor(), authority=current, snapshots=())[0].status == "stale"
    with pytest.raises(ApiError, match="floor_plan_authority_changed"):
        plans.project_entities(
            actor(), authority=current, snapshots=(
                EntitySnapshot("light.living", 24, 11, "verified", "on", NOW),
            ),
        )
    with pytest.raises(ApiError, match="floor_plan_projection_invalid"):
        plans.project_entities(
            actor(), authority=current, snapshots=(
                EntitySnapshot("switch.unknown", 1, 11, "verified", "on", NOW),
            ),
        )
