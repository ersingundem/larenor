from dataclasses import replace

import pytest

from larenor_server.energy_priorities import (
    BatteryInput,
    EnergyAuthority,
    EnergyInputs,
    EnergyPlanner,
    InverterCommandManager,
    InverterReadback,
    ManualOverride,
    MeterInput,
    ReservePolicy,
    SolarForecastInput,
    TariffInput,
)
from larenor_server.errors import ApiError


CORE = "1" * 32
HOME = "2" * 32
ACCOUNT = "3" * 32
FAMILY = "4" * 32
METER = "5" * 32
FORECAST = "6" * 32
TARIFF = "7" * 32
BATTERY = "8" * 32
INVERTER = "9" * 32


class Clock:
    def __init__(self):
        self.ms = 1_000_000

    def __call__(self):
        return self.ms


def authority(**changes):
    values = dict(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        homeRevision=2,
        accountId=ACCOUNT,
        accountRevision=3,
        memberRevision=4,
        sessionFamilyId=FAMILY,
        role="admin",
        active=True,
        canPlan=True,
        canControl=True,
    )
    values.update(changes)
    return EnergyAuthority(**values)


def inputs(*, override=None, battery_changes=None, **changes):
    battery_values = dict(
        schemaVersion=1,
        resourceId=BATTERY,
        revision=9,
        providerRevision=10,
        capturedAtMs=999_900,
        capacityWh=10_000,
        stateOfChargeWh=5_000,
        minimumSocWh=2_000,
        maximumSocWh=9_000,
        maxChargePowerW=2_000,
        maxDischargePowerW=1_000,
    )
    battery_values.update(battery_changes or {})
    values = dict(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        homeRevision=2,
        meter=MeterInput(
            schemaVersion=1,
            resourceId=METER,
            revision=5,
            providerRevision=6,
            capturedAtMs=999_900,
            gridImportPowerW=0,
            gridExportPowerW=0,
        ),
        forecast=SolarForecastInput(
            schemaVersion=1,
            resourceId=FORECAST,
            revision=7,
            providerRevision=8,
            generatedAtMs=999_800,
            startsAtMs=1_000_000,
            slotDurationSeconds=3_600,
            solarEnergyWh=[5_000, 0],
            loadEnergyWh=[0, 4_000],
        ),
        tariff=TariffInput(
            schemaVersion=1,
            resourceId=TARIFF,
            revision=11,
            startsAtMs=1_000_000,
            slotDurationSeconds=3_600,
            importPriceMicrosPerKwh=[100_000, 400_000],
            exportPriceMicrosPerKwh=[50_000, 50_000],
        ),
        battery=BatteryInput(**battery_values),
        reserve=ReservePolicy(
            schemaVersion=1,
            revision=12,
            backupReserveWh=4_000,
        ),
        manualOverride=override,
    )
    values.update(changes)
    return EnergyInputs(**values)


def planner(current_inputs=None, current_authority=None, clock=None):
    live_inputs = current_inputs or inputs()
    live_authority = current_authority or authority()
    return EnergyPlanner(
        authorityResolver=lambda account_id: (
            live_authority if account_id == ACCOUNT else None
        ),
        inputResolver=lambda battery_id: (
            live_inputs if battery_id == BATTERY else None
        ),
        clockMs=clock or Clock(),
    )


def test_revision_bound_advisory_plan_is_deterministic_and_bounded():
    source = inputs()
    service = planner(source)
    first = service.plan(authority(), source)
    second = service.plan(authority(), source)

    assert first == second
    assert first.advisory is True
    assert first.automaticExecutionAllowed is False
    assert first.inputDigest == second.inputDigest
    assert [(slot.action, slot.powerW, slot.projectedSocWh) for slot in first.slots] == [
        ("charge", 2_000, 7_000),
        ("discharge", 1_000, 6_000),
    ]
    assert first.slots[0].reason == "solar_surplus"
    assert first.slots[1].reason == "high_tariff_deficit"

    with pytest.raises(ApiError) as invalid_error:
        service.plan(authority(), {"schemaVersion": 1})
    assert (invalid_error.value.code, invalid_error.value.status) == (
        "invalid_request",
        400,
    )

    for field, value in (
        ("homeRevision", 99),
        ("meter", source.meter.model_copy(update={"revision": 99})),
        ("forecast", source.forecast.model_copy(update={"providerRevision": 99})),
        ("tariff", source.tariff.model_copy(update={"revision": 99})),
        ("battery", source.battery.model_copy(update={"revision": 99})),
        ("reserve", source.reserve.model_copy(update={"revision": 99})),
    ):
        with pytest.raises(ApiError) as error:
            service.plan(authority(), source.model_copy(update={field: value}))
        assert (error.value.code, error.value.status) == ("revision_conflict", 409)


def test_safety_limits_and_expiring_manual_override_win_without_becoming_automatic():
    clock = Clock()
    active = ManualOverride(
        schemaVersion=1,
        revision=13,
        mode="charge",
        powerW=9_000,
        expiresAtMs=clock.ms + 5_000,
    )
    source = inputs(
        override=active,
        battery_changes={"stateOfChargeWh": 8_500},
    )
    active_plan = planner(source, clock=clock).plan(authority(), source)
    assert [(slot.action, slot.powerW, slot.projectedSocWh) for slot in active_plan.slots] == [
        ("charge", 500, 9_000),
        ("hold", 0, 9_000),
    ]
    assert all(slot.reason == "manual_override" for slot in active_plan.slots)
    assert active_plan.automaticExecutionAllowed is False
    assert active_plan.overrideExpiresAtMs == active.expiresAtMs

    worker_calls = []
    manager = InverterCommandManager(
        auditKey=b"override-expiry-audit-key-for-f47",
        authorityResolver=lambda account_id: authority() if account_id == ACCOUNT else None,
        planResolver=lambda plan_id: active_plan if plan_id == active_plan.planId else None,
        worker=lambda command: worker_calls.append(command),
        clockMs=clock,
    )
    preview = manager.preview(
        authority(),
        active_plan,
        slotIndex=0,
        requestId="f" * 32,
        inverterId=INVERTER,
        expectedInverterRevision=14,
    )

    clock.ms = active.expiresAtMs
    with pytest.raises(ApiError) as expiry_error:
        manager.confirm(authority(), preview, preview.confirmationToken)
    assert (expiry_error.value.code, expiry_error.value.status) == (
        "revision_conflict",
        409,
    )
    assert worker_calls == []
    expired_plan = planner(source, clock=clock).plan(authority(), source)
    assert expired_plan.overrideStatus == "expired"
    assert expired_plan.slots[0].reason == "solar_surplus"
    assert expired_plan.slots[0].powerW == 500

    discharge = source.model_copy(
        update={
            "battery": source.battery.model_copy(
                update={"stateOfChargeWh": 4_000}
            ),
            "manualOverride": active.model_copy(
                update={"mode": "discharge", "expiresAtMs": clock.ms + 5_000}
            ),
        }
    )
    reserve_plan = planner(discharge, clock=clock).plan(authority(), discharge)
    assert all(slot.action == "hold" and slot.powerW == 0 for slot in reserve_plan.slots)
    assert all(slot.projectedSocWh == 4_000 for slot in reserve_plan.slots)


def test_preview_confirm_exact_readback_lost_ack_and_audit_tamper_fail_closed():
    clock = Clock()
    source = inputs()
    plan = planner(source, clock=clock).plan(authority(), source)
    live_plan = [plan]
    worker_calls = []

    def worker(command):
        worker_calls.append(command)
        return InverterReadback(
            schemaVersion=1,
            requestId=command.requestId,
            coreId=command.coreId,
            homeId=command.homeId,
            inverterId=command.inverterId,
            inverterRevision=command.expectedInverterRevision,
            batteryId=command.batteryId,
            batteryRevision=command.expectedBatteryRevision,
            inputDigest=command.inputDigest,
            targetPowerW=command.targetPowerW,
            observedPowerW=command.targetPowerW,
            status="applied",
        )

    manager = InverterCommandManager(
        auditKey=b"audit-key-for-f47-energy-priority",
        authorityResolver=lambda account_id: authority() if account_id == ACCOUNT else None,
        planResolver=lambda plan_id: live_plan[0] if plan_id == plan.planId else None,
        worker=worker,
        clockMs=clock,
    )
    preview = manager.preview(
        authority(),
        plan,
        slotIndex=0,
        requestId="a" * 32,
        inverterId=INVERTER,
        expectedInverterRevision=14,
    )
    confirmed = manager.confirm(authority(), preview, preview.confirmationToken)
    assert (confirmed.status, confirmed.readbackVerified) == ("confirmed", True)
    assert manager.confirm(authority(), preview, preview.confirmationToken) == confirmed
    assert len(worker_calls) == 1

    stale_preview = manager.preview(
        authority(),
        plan,
        slotIndex=1,
        requestId="d" * 32,
        inverterId=INVERTER,
        expectedInverterRevision=14,
    )
    live_plan[0] = plan.model_copy(update={"reserveRevision": 99})
    with pytest.raises(ApiError) as stale_error:
        manager.confirm(authority(), stale_preview, stale_preview.confirmationToken)
    assert (stale_error.value.code, stale_error.value.status) == (
        "revision_conflict",
        409,
    )
    assert len(worker_calls) == 1
    live_plan[0] = plan
    with pytest.raises(ApiError) as foreign_session_error:
        manager.confirm(
            authority(sessionFamilyId="e" * 32),
            stale_preview,
            stale_preview.confirmationToken,
        )
    assert (foreign_session_error.value.code, foreign_session_error.value.status) == (
        "revision_conflict",
        409,
    )
    assert len(worker_calls) == 1

    lost_calls = []

    def lost_ack(command):
        lost_calls.append(command)
        raise TimeoutError("private worker detail")

    lost = InverterCommandManager(
        auditKey=b"second-audit-key-for-f47-priority",
        authorityResolver=lambda account_id: authority() if account_id == ACCOUNT else None,
        planResolver=lambda plan_id: plan if plan_id == plan.planId else None,
        worker=lost_ack,
        clockMs=clock,
    )
    uncertain_preview = lost.preview(
        authority(),
        plan,
        slotIndex=1,
        requestId="b" * 32,
        inverterId=INVERTER,
        expectedInverterRevision=14,
    )
    uncertain = lost.confirm(
        authority(), uncertain_preview, uncertain_preview.confirmationToken
    )
    assert (uncertain.status, uncertain.reason) == ("uncertain", "lost_ack")
    assert lost.confirm(
        authority(), uncertain_preview, uncertain_preview.confirmationToken
    ) == uncertain
    assert len(lost_calls) == 1
    assert "private worker detail" not in uncertain.model_dump_json()

    first = lost.audit[0]
    lost._audit[0] = replace(first, entryHash="0" * 64)
    with pytest.raises(ApiError) as error:
        lost.preview(
            authority(),
            plan,
            slotIndex=0,
            requestId="c" * 32,
            inverterId=INVERTER,
            expectedInverterRevision=14,
        )
    assert (error.value.code, error.value.status) == (
        "energy_command_integrity_failed",
        503,
    )
    assert len(lost_calls) == 1
