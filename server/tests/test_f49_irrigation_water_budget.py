import copy

import pytest
from larenor_server.errors import ApiError, StartupError
from larenor_server.garden_irrigation import (
    IrrigationAuthority,
    IrrigationCoordinator,
    IrrigationPlanner,
    IrrigationPolicy,
    IrrigationSafetySnapshot,
    IrrigationZone,
    ManualWaterOverride,
    RainForecast,
    SoilMoistureReading,
    TamperEvidentIrrigationAudit,
    ValveReadback,
    WaterBudget,
    WorkerValveReadback,
)

CORE = "1" * 32
HOME = "2" * 32
ADMIN = "3" * 32
SESSION = "4" * 32
POLICY = "5" * 32
ZONE_A = "6" * 32
ZONE_B = "7" * 32
AREA = "8" * 32
SERVICE = "9" * 32
BINDING_A = "a" * 32
BINDING_B = "b" * 32
SOIL = "c" * 32
WEATHER = "d" * 32


def authority(*, revision=3, active=True):
    return IrrigationAuthority(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        homeRevision=7,
        accountId=ADMIN,
        accountRevision=revision,
        sessionFamilyId=SESSION,
        role="admin",
        active=active,
        canManageIrrigation=True,
    )


def zone(zone_id=ZONE_A, binding=BINDING_A, *, revision=2):
    return IrrigationZone(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        zoneId=zone_id,
        zoneRevision=revision,
        areaId=AREA,
        areaRevision=4,
        valveServiceId=SERVICE,
        valveServiceRevision=5,
        valveBindingId=binding,
        valveBindingRevision=6,
        flowMlPerMinute=4_000,
        maxDurationSeconds=900,
    )


def policy(*, revision=9, zones=None):
    return IrrigationPolicy(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        policyId=POLICY,
        policyRevision=revision,
        zones=zones or [zone()],
        targetMoisturePermille=600,
        soilMaxAgeMs=60_000,
        safetyMaxAgeMs=30_000,
        forecastMaxAgeMs=6 * 60 * 60 * 1000,
        rainDeferralMilliMm=4_000,
        freezeThresholdMilliC=2_000,
        windLimitMilliMps=12_000,
        previewTtlMs=30_000,
        active=True,
    )


def soil(zone_id=ZONE_A, *, moisture=300, revision=11, observed=1_000_000):
    return SoilMoistureReading(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        zoneId=zone_id,
        zoneRevision=2,
        sensorId=SOIL if zone_id == ZONE_A else "e" * 32,
        sensorRevision=3,
        readingRevision=revision,
        moisturePermille=moisture,
        observedAtMs=observed,
    )


def safety(*, leak=False, temperature=15_000, wind=2_000, observed=1_000_000):
    return IrrigationSafetySnapshot(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        safetyRevision=12,
        leakDetected=leak,
        temperatureMilliC=temperature,
        windMilliMps=wind,
        observedAtMs=observed,
    )


def forecast(*, rain=0, revision=13, generated=990_000):
    return RainForecast(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        sourceId=WEATHER,
        sourceRevision=4,
        forecastRevision=revision,
        generatedAtMs=generated,
        validUntilMs=2_000_000,
        rainMilliMm=rain,
    )


def budget(*, used=0, limit=100_000, revision=14):
    return WaterBudget(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        budgetRevision=revision,
        dayStartMs=0,
        dailyLimitMl=limit,
        usedMl=used,
        priceMicrosPerLiter=2_500_000,
    )


def planner(*, current_authority=None, current_policy=None):
    current_authority = current_authority or {ADMIN: authority()}
    current_policy = current_policy or {POLICY: policy()}
    return IrrigationPlanner(
        authorityResolver=lambda account: current_authority.get(account),
        policyResolver=lambda policy_id: current_policy.get(policy_id),
    )


def valve_readback(target=None, *, state_revision=20, open=False):
    target = target or zone()
    return ValveReadback(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        zone=target,
        stateRevision=state_revision,
        valveOpen=open,
        observedAtMs=1_010_000,
    )


def test_plan_is_deterministic_revision_bound_and_budget_limited():
    zones = [zone(ZONE_B, BINDING_B), zone()]
    p = policy(zones=zones)
    service = planner(current_policy={POLICY: p})
    first = service.plan(
        authority(),
        p,
        [soil(ZONE_B), soil()],
        safety(),
        forecast(),
        budget(limit=30_000),
        nowMs=1_020_000,
    )
    second = service.plan(
        authority(),
        p,
        [soil(), soil(ZONE_B)],
        safety(),
        forecast(),
        budget(limit=30_000),
        nowMs=1_020_000,
    )
    assert first == second
    assert [item.zone.zoneId for item in first.items] == [ZONE_A, ZONE_B]
    assert first.totalWaterMl <= 30_000
    assert first.estimatedCostMicros == first.totalWaterMl * 2_500_000 // 1000
    assert first.inputRevisions.model_dump() == {
        "schemaVersion": 1,
        "policyRevision": 9,
        "safetyRevision": 12,
        "forecastRevision": 13,
        "budgetRevision": 14,
        "forecastSourceId": WEATHER,
        "forecastSourceRevision": 4,
        "soilSensorIds": {ZONE_A: SOIL, ZONE_B: "e" * 32},
        "soilSensorRevisions": {ZONE_A: 3, ZONE_B: 3},
        "soilReadingRevisions": {ZONE_A: 11, ZONE_B: 11},
    }


def test_forecast_is_advisory_but_leak_freeze_wind_and_stale_sensors_block():
    service = planner()
    rainy = service.plan(
        authority(),
        policy(),
        [soil()],
        safety(),
        forecast(rain=8_000),
        budget(),
        nowMs=1_020_000,
    )
    assert rainy.items[0].status == "deferred"
    assert rainy.items[0].reason == "rain_forecast"
    override = ManualWaterOverride(
        schemaVersion=1,
        overrideId="f" * 32,
        coreId=CORE,
        homeId=HOME,
        policyId=POLICY,
        expectedPolicyRevision=9,
        zoneId=ZONE_A,
        expectedZoneRevision=2,
        actorAccountId=ADMIN,
        durationSeconds=120,
        createdAtMs=1_010_000,
        expiresAtMs=1_040_000,
    )
    overridden = service.plan(
        authority(),
        policy(),
        [soil()],
        safety(),
        forecast(rain=8_000),
        budget(),
        nowMs=1_020_000,
        overrides=[override],
    )
    assert overridden.items[0].status == "planned"
    assert overridden.items[0].reason == "manual_override"

    cases = (
        (safety(leak=True), soil(), "leak_detected"),
        (safety(temperature=1_000), soil(), "freeze_risk"),
        (safety(wind=13_000), soil(), "wind_risk"),
        (safety(observed=900_000), soil(), "safety_stale"),
        (safety(), soil(observed=900_000), "soil_sensor_stale"),
    )
    for safe, reading, reason in cases:
        result = planner().plan(
            authority(),
            policy(),
            [reading],
            safe,
            forecast(),
            budget(),
            nowMs=1_020_000,
            overrides=[override],
        )
        assert result.items[0].status == "blocked"
        assert result.items[0].reason == reason
        assert result.totalWaterMl == 0


def test_manual_override_expires_and_stale_scope_or_input_revision_fails_closed():
    override = ManualWaterOverride(
        schemaVersion=1,
        overrideId="f" * 32,
        coreId=CORE,
        homeId=HOME,
        policyId=POLICY,
        expectedPolicyRevision=9,
        zoneId=ZONE_A,
        expectedZoneRevision=2,
        actorAccountId=ADMIN,
        durationSeconds=120,
        createdAtMs=1_000_000,
        expiresAtMs=1_020_000,
    )
    result = planner().plan(
        authority(),
        policy(),
        [soil(moisture=650)],
        safety(),
        forecast(rain=8_000),
        budget(),
        nowMs=1_020_000,
        overrides=[override],
    )
    assert result.items[0].status == "skipped"
    assert result.items[0].reason == "moisture_sufficient"

    with pytest.raises(ApiError, match="revision_conflict"):
        planner(current_authority={ADMIN: authority(revision=4)}).plan(
            authority(),
            policy(),
            [soil()],
            safety(),
            forecast(),
            budget(),
            nowMs=1_020_000,
        )
    with pytest.raises(ApiError, match="revision_conflict"):
        planner().plan(
            authority(),
            policy(),
            [soil().model_copy(update={"zoneRevision": 3})],
            safety(),
            forecast(),
            budget(),
            nowMs=1_020_000,
        )


def test_preview_confirm_requires_exact_live_scope_and_verified_flow_readback():
    p = policy()
    current_authority = {ADMIN: authority()}
    current_policy = {POLICY: p}
    plan = planner(
        current_authority=current_authority, current_policy=current_policy
    ).plan(
        authority(),
        p,
        [soil()],
        safety(),
        forecast(),
        budget(),
        nowMs=1_020_000,
    )
    audit = TamperEvidentIrrigationAudit(key=b"i" * 32, coreId=CORE, homeId=HOME)
    coordinator = IrrigationCoordinator(
        audit=audit,
        authorityResolver=lambda account: current_authority.get(account),
        policyResolver=lambda policy_id: current_policy.get(policy_id),
        planResolver=lambda plan_id: plan if plan_id == plan.planId else None,
        maxReceipts=8,
    )
    with pytest.raises(ApiError, match="revision_conflict"):
        coordinator.preview(
            authority(),
            plan.model_copy(update={"totalWaterMl": plan.totalWaterMl + 1}),
            [valve_readback()],
            requestId="0" * 32,
            nowMs=1_020_000,
        )
    preview = coordinator.preview(
        authority(),
        plan,
        [valve_readback()],
        requestId="1" * 32,
        nowMs=1_020_000,
    )
    assert (
        coordinator.preview(
            authority(),
            plan,
            [valve_readback()],
            requestId="1" * 32,
            nowMs=1_020_000,
        )
        == preview
    )
    commands = []

    def worker(command):
        commands.append(command)
        return WorkerValveReadback(
            schemaVersion=1,
            commandId=command.commandId,
            zone=command.zone,
            stateRevision=command.expectedStateRevision + 1,
            valveOpen=False,
            deliveredMl=command.expectedWaterMl,
            flowVerified=True,
            observedAtMs=1_021_000,
        )

    receipt = coordinator.confirm(
        authority(),
        preview.previewId,
        preview.confirmToken,
        nowMs=1_020_100,
        worker=worker,
    )
    assert receipt.status == "applied"
    assert receipt.results[0].status == "applied"
    assert receipt.results[0].readback.flowVerified is True
    assert len(commands) == 1
    assert (
        coordinator.confirm(
            authority(),
            preview.previewId,
            preview.confirmToken,
            nowMs=1_020_200,
            worker=worker,
        )
        == receipt
    )
    assert len(commands) == 1


def test_lost_ack_and_no_flow_never_replay_or_report_success():
    p = policy()
    plan = planner().plan(
        authority(),
        p,
        [soil()],
        safety(),
        forecast(),
        budget(),
        nowMs=1_020_000,
    )
    audit = TamperEvidentIrrigationAudit(key=b"i" * 32, coreId=CORE, homeId=HOME)
    coordinator = IrrigationCoordinator(
        audit=audit,
        authorityResolver=lambda _account: authority(),
        policyResolver=lambda _policy: p,
        planResolver=lambda plan_id: plan if plan_id == plan.planId else None,
        maxReceipts=8,
    )
    preview = coordinator.preview(
        authority(),
        plan,
        [valve_readback()],
        requestId="2" * 32,
        nowMs=1_020_000,
    )
    calls = []

    def lost(command):
        calls.append(command.commandId)
        raise TimeoutError("lost ack")

    unknown = coordinator.confirm(
        authority(),
        preview.previewId,
        preview.confirmToken,
        nowMs=1_020_100,
        worker=lost,
    )
    assert unknown.status == "unknown"
    assert unknown.results[0].code == "worker_ack_unknown"
    coordinator.confirm(
        authority(),
        preview.previewId,
        preview.confirmToken,
        nowMs=1_020_200,
        worker=lost,
    )
    assert len(calls) == 1

    second = coordinator.preview(
        authority(),
        plan,
        [valve_readback()],
        requestId="3" * 32,
        nowMs=1_020_000,
    )
    failed = coordinator.confirm(
        authority(),
        second.previewId,
        second.confirmToken,
        nowMs=1_020_100,
        worker=lambda command: WorkerValveReadback(
            schemaVersion=1,
            commandId=command.commandId,
            zone=command.zone,
            stateRevision=command.expectedStateRevision + 1,
            valveOpen=False,
            deliveredMl=0,
            flowVerified=False,
            observedAtMs=1_021_000,
        ),
    )
    assert failed.status == "failed"
    assert failed.results[0].code == "flow_not_verified"


def test_audit_chain_detects_event_and_head_tampering_and_is_bounded():
    audit = TamperEvidentIrrigationAudit(
        key=b"i" * 32,
        coreId=CORE,
        homeId=HOME,
        maxEvents=2,
    )
    audit.append(
        kind="plan",
        policyId=POLICY,
        policyRevision=9,
        actorAccountId=ADMIN,
        requestId="1" * 32,
        status="planned",
        payloadHash="0" * 64,
        atMs=1_000_000,
    )
    exported = audit.export()
    assert (
        TamperEvidentIrrigationAudit.restore(
            exported,
            key=b"i" * 32,
            coreId=CORE,
            homeId=HOME,
            maxEvents=2,
        )
        .events()[0]
        .status
        == "planned"
    )
    for path in ("event", "head"):
        changed = copy.deepcopy(exported)
        if path == "event":
            changed["events"][0]["payloadHash"] = "1" * 64
        else:
            changed["headTag"] = "1" * 64
        with pytest.raises(StartupError, match="irrigation_audit_invalid"):
            TamperEvidentIrrigationAudit.restore(
                changed,
                key=b"i" * 32,
                coreId=CORE,
                homeId=HOME,
                maxEvents=2,
            )
    audit.append(
        kind="result",
        policyId=POLICY,
        policyRevision=9,
        actorAccountId=ADMIN,
        requestId="1" * 32,
        status="applied",
        payloadHash="2" * 64,
        atMs=1_000_001,
    )
    with pytest.raises(ApiError, match="irrigation_audit_limit"):
        audit.append(
            kind="result",
            policyId=POLICY,
            policyRevision=9,
            actorAccountId=ADMIN,
            requestId="2" * 32,
            status="applied",
            payloadHash="2" * 64,
            atMs=1_000_002,
        )
