from dataclasses import replace
from pathlib import Path

import pytest

from larenor_server.auth import Principal
from larenor_server.database import Database
from larenor_server.errors import ApiError, StartupError
from larenor_server.ev_charging.schema import migrate_ev_charging
from larenor_server.ev_charging.service import (
    ChargeAuthority,
    ChargeGoal,
    ChargePlanner,
    EnergyInputs,
    EnergySlot,
    ManualOverride,
    ProviderState,
)


AUDIT_KEY = bytes.fromhex("46" * 32)
NOW = 1_800_000_000.0


def actor() -> Principal:
    return Principal("ada", "ada", "member", False, "session-a", "token")


def authority(*, schedule_revision: int = 7) -> ChargeAuthority:
    return ChargeAuthority(
        core_id="core-a",
        home_id="home-a",
        account_id="ada",
        session_id="session-a",
        core_revision=3,
        home_revision=5,
        account_revision=9,
        charger_id="charger-garage",
        charger_revision=13,
        tariff_revision=17,
        solar_revision=19,
        power_budget_revision=23,
        override_revision=29,
        schedule_revision=schedule_revision,
        max_current_amp=16,
        voltage=230,
        max_session_wh=20_000,
        can_control=True,
    )


def inputs(*, override_until: float | None = None) -> EnergyInputs:
    states = (
        ProviderState("tariff", 17, "verified", NOW),
        ProviderState("solar", 19, "verified", NOW),
        ProviderState("power_budget", 23, "verified", NOW),
    )
    slots = (
        EnergySlot(NOW + 0, NOW + 3600, 40, 0, 3680),
        EnergySlot(NOW + 3600, NOW + 7200, 35, 1000, 2680),
        EnergySlot(NOW + 7200, NOW + 10800, 10, 0, 3680),
        EnergySlot(NOW + 10800, NOW + 14400, 20, 2000, 1680),
    )
    return EnergyInputs(
        tariff_revision=17,
        solar_revision=19,
        power_budget_revision=23,
        override_revision=29,
        provider_states=states,
        slots=slots,
        manual_override=None if override_until is None else ManualOverride(
            expires_at=override_until,
            max_current_amp=8,
            reason="driver-control",
        ),
    )


def goal() -> ChargeGoal:
    return ChargeGoal(
        departure_at=NOW + 14400,
        current_soc=40,
        minimum_soc=50,
        target_soc=60,
        battery_capacity_wh=40_000,
        max_current_amp=16,
    )


class FakeCharger:
    def __init__(self):
        self.apply_calls = 0
        self.timeout = False
        self.observed_hash = None

    def apply(self, *, plan_hash: str, slots: tuple[dict, ...]) -> None:
        self.apply_calls += 1
        if self.timeout:
            raise TimeoutError
        self.observed_hash = plan_hash

    def readback(self) -> str | None:
        return self.observed_hash


def planner(path: Path, charger: FakeCharger | None = None) -> ChargePlanner:
    database = Database(path)
    if not path.exists():
        database.create_schema()
    with database.transaction() as connection:
        migrate_ev_charging(connection)
    return ChargePlanner(
        database,
        audit_key=AUDIT_KEY,
        charger=charger or FakeCharger(),
        clock=lambda: NOW,
    )


def test_revision_bound_inputs_produce_deterministic_bounded_safe_plan(tmp_path):
    service = planner(tmp_path / "core.sqlite3")
    preview = service.preview(
        actor(), authority=authority(), inputs=inputs(), goal=goal(),
        preview_id="preview-1",
    )
    assert preview.status == "ready"
    assert preview.required_wh == 8_000
    assert sum(slot.energy_wh for slot in preview.slots) == 8_000
    assert [slot.start_at for slot in preview.slots] == [
        NOW + 7200,
        NOW + 10800,
        NOW + 3600,
    ]
    assert all(slot.current_amp <= 16 for slot in preview.slots)
    assert preview.provider_status == {
        "power_budget": "verified", "solar": "verified", "tariff": "verified"
    }

    stale = replace(inputs(), provider_states=(
        ProviderState("tariff", 17, "stale", NOW),
        *inputs().provider_states[1:],
    ))
    with pytest.raises(ApiError, match="energy_inputs_unverified"):
        service.preview(
            actor(), authority=authority(), inputs=stale, goal=goal(),
            preview_id="preview-stale",
        )
    with pytest.raises(ApiError, match="energy_authority_changed"):
        service.preview(
            actor(), authority=authority(),
            inputs=replace(inputs(), tariff_revision=16), goal=goal(),
            preview_id="preview-revision",
        )


def test_safety_limits_and_manual_override_expiry_fail_closed(tmp_path):
    service = planner(tmp_path / "core.sqlite3")
    active = service.preview(
        actor(), authority=authority(), inputs=inputs(override_until=NOW + 300),
        goal=goal(), preview_id="preview-override",
    )
    assert active.status == "manual_override_active"
    assert active.slots == ()
    assert active.override_expires_at == NOW + 300

    expired = service.preview(
        actor(), authority=authority(), inputs=inputs(override_until=NOW - 1),
        goal=goal(), preview_id="preview-after-override",
    )
    assert expired.status == "ready"
    with pytest.raises(ApiError, match="charge_safety_limit"):
        service.preview(
            actor(), authority=authority(), inputs=inputs(),
            goal=replace(goal(), max_current_amp=17), preview_id="preview-unsafe",
        )
    with pytest.raises(ApiError, match="charge_target_unreachable"):
        service.preview(
            actor(), authority=authority(), inputs=inputs(),
            goal=replace(goal(), target_soc=100), preview_id="preview-impossible",
        )


def test_preview_confirm_readback_lost_ack_never_replays_and_audit_detects_tamper(tmp_path):
    path = tmp_path / "core.sqlite3"
    charger = FakeCharger()
    service = planner(path, charger)
    preview = service.preview(
        actor(), authority=authority(), inputs=inputs(), goal=goal(),
        preview_id="preview-1",
    )
    charger.timeout = True
    uncertain = service.confirm(
        actor(), authority=authority(), preview_id=preview.id,
        command_id="confirm-1", expected_plan_hash=preview.plan_hash,
    )
    assert uncertain.status == "uncertain"
    same = service.confirm(
        actor(), authority=authority(), preview_id=preview.id,
        command_id="confirm-1", expected_plan_hash=preview.plan_hash,
    )
    assert same == uncertain
    assert charger.apply_calls == 1

    assert service.readback(
        actor(), authority=authority(), command_id="confirm-1"
    ).status == "uncertain"
    charger.observed_hash = preview.plan_hash
    verified = service.readback(
        actor(), authority=authority(), command_id="confirm-1"
    )
    assert verified.status == "verified"
    assert charger.apply_calls == 1

    with Database(path).transaction() as connection:
        connection.execute(
            "UPDATE ev_charge_events SET actor_id='mallory' WHERE sequence=1"
        )
    with pytest.raises(StartupError, match="ev_charge_audit_invalid"):
        planner(path, charger).history(actor(), authority=authority(), limit=20)
