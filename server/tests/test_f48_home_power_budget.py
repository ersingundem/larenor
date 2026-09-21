from dataclasses import replace
from pathlib import Path

import pytest
from larenor_server.auth import Principal
from larenor_server.database import Database
from larenor_server.errors import ApiError, StartupError
from larenor_server.power_budget.schema import migrate_power_budget
from larenor_server.power_budget.service import (
    BudgetAuthority,
    BudgetInputs,
    LoadState,
    ManualOverride,
    PowerBudgetService,
    ProviderState,
)

AUDIT_KEY = bytes.fromhex("48" * 32)
NOW = 1_800_000_000.0


def actor() -> Principal:
    return Principal("ada", "ada", "member", False, "session-a", "token")


def authority(*, plan_revision: int = 31) -> BudgetAuthority:
    return BudgetAuthority(
        core_id="core-a",
        home_id="home-a",
        account_id="ada",
        session_id="session-a",
        core_revision=3,
        home_revision=5,
        account_revision=7,
        meter_id="meter-main",
        meter_revision=11,
        tariff_revision=13,
        load_registry_revision=17,
        grid_limit_revision=19,
        override_revision=23,
        plan_revision=plan_revision,
        max_grid_w=12_000,
        max_shed_w=8_000,
        can_control=True,
    )


def inputs(*, grid_import_w: int = 11_500, override_until: float | None = None):
    return BudgetInputs(
        meter_revision=11,
        tariff_revision=13,
        load_registry_revision=17,
        grid_limit_revision=19,
        override_revision=23,
        grid_limit_w=8_000,
        grid_import_w=grid_import_w,
        tariff_micros_per_kwh=1_250_000,
        provider_states=(
            ProviderState("meter", 11, "verified", NOW),
            ProviderState("tariff", 13, "verified", NOW),
        ),
        loads=(
            LoadState("medical-fridge", 1, 100, 500, True, False, 0),
            LoadState("ev-charger", 2, 10, 3_000, False, True, 0),
            LoadState("dryer", 4, 20, 2_000, False, True, 0),
            LoadState("dishwasher", 6, 30, 1_000, False, True, 0),
        ),
        manual_override=None
        if override_until is None
        else ManualOverride(
            expires_at=override_until,
            reason="resident-control",
        ),
    )


class FakeWorker:
    def __init__(self):
        self.apply_calls = 0
        self.timeout = False
        self.observed_hash = None
        self.actions = ()

    def apply(self, *, plan_hash: str, actions: tuple[dict, ...]) -> None:
        self.apply_calls += 1
        self.actions = actions
        if self.timeout:
            raise TimeoutError
        self.observed_hash = plan_hash

    def readback(self) -> str | None:
        return self.observed_hash


def service(path: Path, worker: FakeWorker | None = None) -> PowerBudgetService:
    database = Database(path)
    if not path.exists():
        database.create_schema()
    with database.transaction() as connection:
        migrate_power_budget(connection)
    return PowerBudgetService(
        database,
        audit_key=AUDIT_KEY,
        worker=worker or FakeWorker(),
        clock=lambda: NOW,
    )


def test_revision_bound_verified_inputs_make_deterministic_bounded_shedding_plan(
    tmp_path,
):
    budget = service(tmp_path / "core.sqlite3")
    preview = budget.preview(
        actor(), authority=authority(), inputs=inputs(), preview_id="preview-1"
    )
    assert preview.status == "ready"
    assert preview.required_reduction_w == 3_500
    assert [(action.load_id, action.reduction_w) for action in preview.actions] == [
        ("ev-charger", 3_000),
        ("dryer", 500),
    ]
    assert all(action.load_id != "medical-fridge" for action in preview.actions)
    assert preview.provider_status == {"meter": "verified", "tariff": "verified"}

    stale = replace(
        inputs(),
        provider_states=(
            ProviderState("meter", 11, "stale", NOW),
            ProviderState("tariff", 13, "verified", NOW),
        ),
    )
    with pytest.raises(ApiError, match="power_inputs_unverified"):
        budget.preview(
            actor(), authority=authority(), inputs=stale, preview_id="preview-stale"
        )
    with pytest.raises(ApiError, match="power_authority_changed"):
        budget.preview(
            actor(),
            authority=authority(),
            inputs=replace(inputs(), meter_revision=10),
            preview_id="preview-revision",
        )


def test_critical_load_hold_and_manual_override_expiry_fail_closed(tmp_path):
    budget = service(tmp_path / "core.sqlite3")
    active = budget.preview(
        actor(),
        authority=authority(),
        inputs=inputs(override_until=NOW + 300),
        preview_id="preview-override",
    )
    assert active.status == "manual_override_active"
    assert active.actions == ()
    assert active.override_expires_at == NOW + 300

    expired = budget.preview(
        actor(),
        authority=authority(),
        inputs=inputs(override_until=NOW - 1),
        preview_id="preview-expired",
    )
    assert expired.status == "ready"

    protected = replace(
        inputs(grid_import_w=12_000),
        loads=tuple(
            replace(load, hold_until=NOW + 600) if not load.critical else load
            for load in inputs().loads
        ),
    )
    with pytest.raises(ApiError, match="critical_load_protection"):
        budget.preview(
            actor(),
            authority=authority(),
            inputs=protected,
            preview_id="preview-protected",
        )
    with pytest.raises(ApiError, match="power_safety_limit"):
        budget.preview(
            actor(),
            authority=authority(),
            inputs=replace(inputs(), grid_limit_w=13_000),
            preview_id="preview-unsafe",
        )


def test_preview_confirm_readback_lost_ack_never_replays_and_audit_detects_tamper(
    tmp_path,
):
    path = tmp_path / "core.sqlite3"
    worker = FakeWorker()
    budget = service(path, worker)
    preview = budget.preview(
        actor(), authority=authority(), inputs=inputs(), preview_id="preview-1"
    )
    worker.timeout = True
    uncertain = budget.confirm(
        actor(),
        authority=authority(),
        preview_id=preview.id,
        command_id="command-1",
        expected_plan_hash=preview.plan_hash,
    )
    assert uncertain.status == "uncertain"
    same = service(path, worker).confirm(
        actor(),
        authority=authority(),
        preview_id=preview.id,
        command_id="command-1",
        expected_plan_hash=preview.plan_hash,
    )
    assert same == uncertain
    assert worker.apply_calls == 1
    assert [
        (action["load_id"], action["reduction_w"]) for action in worker.actions
    ] == [
        ("ev-charger", 3_000),
        ("dryer", 500),
    ]

    with pytest.raises(ApiError, match="power_authority_changed"):
        budget.readback(
            actor(), authority=authority(plan_revision=32), command_id="command-1"
        )
    assert (
        budget.readback(actor(), authority=authority(), command_id="command-1").status
        == "uncertain"
    )
    worker.observed_hash = preview.plan_hash
    assert (
        budget.readback(actor(), authority=authority(), command_id="command-1").status
        == "verified"
    )
    assert worker.apply_calls == 1

    with Database(path).transaction() as connection:
        connection.execute(
            "UPDATE power_budget_events SET actor_id='mallory' WHERE sequence=1"
        )
    with pytest.raises(StartupError, match="power_budget_audit_invalid"):
        service(path, worker).history(actor(), authority=authority(), limit=20)
