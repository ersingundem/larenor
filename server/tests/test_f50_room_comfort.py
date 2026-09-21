import copy

import pytest

from larenor_server.errors import ApiError, StartupError
from larenor_server.room_comfort import (
    ComfortAuthority,
    ComfortCoordinator,
    ComfortDevice,
    ComfortDeviceReadback,
    ComfortPlanner,
    ComfortPolicy,
    ManualComfortOverride,
    MetricReading,
    OccupancySnapshot,
    OutdoorWeatherSnapshot,
    RoomClimateSnapshot,
    RoomComfortScope,
    TamperEvidentComfortAudit,
    WorkerComfortReadback,
)


CORE = "1" * 32
HOME = "2" * 32
ADMIN = "3" * 32
SESSION = "4" * 32
POLICY = "5" * 32
ROOM = "6" * 32
AREA = "7" * 32
HVAC = "8" * 32
WINDOW = "9" * 32
SERVICE = "a" * 32
WEATHER = "b" * 32
OCCUPANCY = "c" * 32


def authority(*, revision=3, active=True):
    return ComfortAuthority(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        homeRevision=7,
        accountId=ADMIN,
        accountRevision=revision,
        sessionFamilyId=SESSION,
        role="admin",
        active=active,
        canManageComfort=True,
    )


def device(kind, device_id, binding_id):
    return ComfortDevice(
        schemaVersion=1,
        kind=kind,
        deviceId=device_id,
        deviceRevision=2,
        serviceId=SERVICE,
        serviceRevision=3,
        bindingId=binding_id,
        bindingRevision=4,
    )


def room():
    return RoomComfortScope(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        roomId=ROOM,
        roomRevision=5,
        areaId=AREA,
        areaRevision=6,
        hvac=device("hvac", HVAC, "d" * 32),
        window=device("window", WINDOW, "e" * 32),
    )


def policy(*, revision=10):
    return ComfortPolicy(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        policyId=POLICY,
        policyRevision=revision,
        rooms=[room()],
        targetTemperatureMilliC=22_000,
        temperatureToleranceMilliC=1_000,
        humidityHighPermille=700,
        co2HighPpm=1_000,
        vocHighPpb=500,
        outdoorAqiLimit=100,
        freezeThresholdMilliC=3_000,
        indoorMaxAgeMs=60_000,
        outdoorMaxAgeMs=120_000,
        occupancyMaxAgeMs=60_000,
        previewTtlMs=30_000,
        active=True,
    )


def metric(kind, value, suffix, *, observed=1_000_000, revision=11):
    return MetricReading(
        schemaVersion=1,
        kind=kind,
        sensorId=suffix * 32,
        sensorRevision=2,
        readingRevision=revision,
        value=value,
        observedAtMs=observed,
    )


def climate(
    *,
    temperature=22_000,
    humidity=500,
    co2=700,
    voc=200,
    smoke=False,
    observed=1_000_000,
):
    return RoomClimateSnapshot(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        roomId=ROOM,
        roomRevision=5,
        snapshotRevision=12,
        temperature=metric("temperature_millic", temperature, "1", observed=observed),
        humidity=metric("humidity_permille", humidity, "2", observed=observed),
        co2=metric("co2_ppm", co2, "3", observed=observed),
        voc=metric("voc_ppb", voc, "4", observed=observed),
        smokeDetected=smoke,
        smokeSensorId="5" * 32,
        smokeSensorRevision=2,
        smokeReadingRevision=11,
        smokeObservedAtMs=observed,
    )


def weather(*, temperature=12_000, raining=False, aqi=40, observed=990_000):
    return OutdoorWeatherSnapshot(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        sourceId=WEATHER,
        sourceRevision=3,
        weatherRevision=13,
        temperatureMilliC=temperature,
        raining=raining,
        airQualityIndex=aqi,
        observedAtMs=observed,
    )


def occupancy(*, occupied=True, observed=1_000_000):
    return OccupancySnapshot(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        roomId=ROOM,
        roomRevision=5,
        sourceId=OCCUPANCY,
        sourceRevision=4,
        occupancyRevision=14,
        occupied=occupied,
        observedAtMs=observed,
    )


def planner(*, current_authority=None, current_policy=None):
    current_authority = current_authority or {ADMIN: authority()}
    current_policy = current_policy or {POLICY: policy()}
    return ComfortPlanner(
        authorityResolver=lambda account: current_authority.get(account),
        policyResolver=lambda policy_id: current_policy.get(policy_id),
    )


def readbacks():
    return [
        ComfortDeviceReadback(
            schemaVersion=1,
            coreId=CORE,
            homeId=HOME,
            roomId=ROOM,
            device=room().hvac,
            stateRevision=20,
            state="off",
            observedAtMs=1_010_000,
        ),
        ComfortDeviceReadback(
            schemaVersion=1,
            coreId=CORE,
            homeId=HOME,
            roomId=ROOM,
            device=room().window,
            stateRevision=21,
            state="closed",
            observedAtMs=1_010_000,
        ),
    ]


def test_plan_is_deterministic_revision_bound_and_occupancy_is_advisory_only():
    service = planner()
    occupied = service.plan(
        authority(),
        policy(),
        [climate(co2=1_400)],
        weather(),
        [occupancy()],
        nowMs=1_020_000,
    )
    empty = service.plan(
        authority(),
        policy(),
        [climate(co2=1_400)],
        weather(),
        [occupancy(occupied=False)],
        nowMs=1_020_000,
    )
    assert occupied.items[0].windowState == "open"
    assert empty.items[0].windowState == "open"
    assert occupied.items[0].reason == "air_refresh"
    assert empty.occupancyAdvisory == {ROOM: "unoccupied"}
    assert occupied.inputRevisions.model_dump() == {
        "schemaVersion": 1,
        "policyRevision": 10,
        "weatherRevision": 13,
        "weatherSourceId": WEATHER,
        "weatherSourceRevision": 3,
        "roomSnapshotRevisions": {ROOM: 12},
        "occupancyRevisions": {ROOM: 14},
        "occupancySourceIds": {ROOM: OCCUPANCY},
        "occupancySourceRevisions": {ROOM: 4},
        "metricSensorRevisions": {
            ROOM: {
                "temperature_millic": 2,
                "humidity_permille": 2,
                "co2_ppm": 2,
                "voc_ppb": 2,
            }
        },
        "metricReadingRevisions": {
            ROOM: {
                "temperature_millic": 11,
                "humidity_permille": 11,
                "co2_ppm": 11,
                "voc_ppb": 11,
            }
        },
        "smokeSensorRevisions": {ROOM: 2},
        "smokeReadingRevisions": {ROOM: 11},
    }


def test_stale_smoke_freeze_rain_window_and_outdoor_air_quality_fail_safe():
    override = ManualComfortOverride(
        schemaVersion=1,
        overrideId="f" * 32,
        coreId=CORE,
        homeId=HOME,
        policyId=POLICY,
        expectedPolicyRevision=10,
        roomId=ROOM,
        expectedRoomRevision=5,
        actorAccountId=ADMIN,
        hvacMode="off",
        windowState="open",
        createdAtMs=1_000_000,
        expiresAtMs=1_040_000,
    )
    cases = (
        (climate(observed=900_000), weather(), "sensor_stale"),
        (climate(smoke=True), weather(), "smoke_detected"),
        (climate(), weather(temperature=2_000), "freeze_risk"),
        (climate(co2=1_400), weather(raining=True), "rain_window_block"),
        (climate(co2=1_400), weather(aqi=140), "outdoor_air_unsafe"),
    )
    for indoor, outside, reason in cases:
        result = planner().plan(
            authority(),
            policy(),
            [indoor],
            outside,
            [occupancy()],
            nowMs=1_020_000,
            overrides=[override],
        )
        item = result.items[0]
        assert item.status == "blocked"
        assert item.reason == reason
        assert item.hvacMode == "off" and item.windowState == "closed"


def test_manual_override_expires_and_exact_scope_revisions_fail_closed():
    override = ManualComfortOverride(
        schemaVersion=1,
        overrideId="f" * 32,
        coreId=CORE,
        homeId=HOME,
        policyId=POLICY,
        expectedPolicyRevision=10,
        roomId=ROOM,
        expectedRoomRevision=5,
        actorAccountId=ADMIN,
        hvacMode="cool",
        windowState="closed",
        createdAtMs=1_000_000,
        expiresAtMs=1_020_000,
    )
    result = planner().plan(
        authority(),
        policy(),
        [climate()],
        weather(),
        [occupancy()],
        nowMs=1_020_000,
        overrides=[override],
    )
    assert result.items[0].reason == "comfortable"
    with pytest.raises(ApiError, match="revision_conflict"):
        planner(current_authority={ADMIN: authority(revision=4)}).plan(
            authority(),
            policy(),
            [climate()],
            weather(),
            [occupancy()],
            nowMs=1_020_000,
        )
    with pytest.raises(ApiError, match="revision_conflict"):
        planner().plan(
            authority(),
            policy(),
            [climate().model_copy(update={"roomRevision": 6})],
            weather(),
            [occupancy()],
            nowMs=1_020_000,
        )


def test_preview_confirm_uses_trusted_plan_and_exact_hvac_window_readback():
    p = policy()
    auth_map, policy_map = {ADMIN: authority()}, {POLICY: p}
    plan = planner(current_authority=auth_map, current_policy=policy_map).plan(
        authority(),
        p,
        [climate(co2=1_400)],
        weather(),
        [occupancy()],
        nowMs=1_020_000,
    )
    audit = TamperEvidentComfortAudit(key=b"c" * 32, coreId=CORE, homeId=HOME)
    coordinator = ComfortCoordinator(
        audit=audit,
        authorityResolver=lambda account: auth_map.get(account),
        policyResolver=lambda policy_id: policy_map.get(policy_id),
        planResolver=lambda plan_id: plan if plan_id == plan.planId else None,
        maxReceipts=8,
    )
    with pytest.raises(ApiError, match="revision_conflict"):
        coordinator.preview(
            authority(),
            plan.model_copy(update={"policyRevision": 11}),
            readbacks(),
            requestId="0" * 32,
            nowMs=1_020_000,
        )
    preview = coordinator.preview(
        authority(),
        plan,
        readbacks(),
        requestId="1" * 32,
        nowMs=1_020_000,
    )
    calls = []

    def worker(command):
        calls.append(command.targetKind)
        return WorkerComfortReadback(
            schemaVersion=1,
            commandId=command.commandId,
            roomId=command.roomId,
            device=command.device,
            stateRevision=command.expectedStateRevision + 1,
            state=command.desiredState,
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
    assert calls == ["window"]
    assert receipt.results[0].readback.state == "open"


def test_lost_ack_is_unknown_and_duplicate_confirm_never_replays():
    p = policy()
    plan = planner().plan(
        authority(),
        p,
        [climate(temperature=19_000)],
        weather(),
        [occupancy()],
        nowMs=1_020_000,
    )
    coordinator = ComfortCoordinator(
        audit=TamperEvidentComfortAudit(key=b"c" * 32, coreId=CORE, homeId=HOME),
        authorityResolver=lambda _account: authority(),
        policyResolver=lambda _policy: p,
        planResolver=lambda plan_id: plan if plan_id == plan.planId else None,
        maxReceipts=8,
    )
    preview = coordinator.preview(
        authority(),
        plan,
        readbacks(),
        requestId="2" * 32,
        nowMs=1_020_000,
    )
    calls = []

    def lost(command):
        calls.append(command.commandId)
        raise TimeoutError("lost ack")

    first = coordinator.confirm(
        authority(),
        preview.previewId,
        preview.confirmToken,
        nowMs=1_020_100,
        worker=lost,
    )
    second = coordinator.confirm(
        authority(),
        preview.previewId,
        preview.confirmToken,
        nowMs=1_020_200,
        worker=lost,
    )
    assert first == second
    assert first.status == "unknown" and first.results[0].code == "worker_ack_unknown"
    assert len(calls) == 1


def test_audit_detects_event_and_head_tampering_and_is_bounded():
    audit = TamperEvidentComfortAudit(
        key=b"c" * 32,
        coreId=CORE,
        homeId=HOME,
        maxEvents=2,
    )
    audit.append(
        kind="plan",
        policyId=POLICY,
        policyRevision=10,
        actorAccountId=ADMIN,
        requestId="1" * 32,
        status="planned",
        payloadHash="0" * 64,
        atMs=1_000_000,
    )
    exported = audit.export()
    assert (
        TamperEvidentComfortAudit.restore(
            exported,
            key=b"c" * 32,
            coreId=CORE,
            homeId=HOME,
            maxEvents=2,
        )
        .events()[0]
        .status
        == "planned"
    )
    for where in ("event", "head"):
        changed = copy.deepcopy(exported)
        if where == "event":
            changed["events"][0]["status"] = "applied"
        else:
            changed["headTag"] = "1" * 64
        with pytest.raises(StartupError, match="comfort_audit_invalid"):
            TamperEvidentComfortAudit.restore(
                changed,
                key=b"c" * 32,
                coreId=CORE,
                homeId=HOME,
                maxEvents=2,
            )
    audit.append(
        kind="result",
        policyId=POLICY,
        policyRevision=10,
        actorAccountId=ADMIN,
        requestId="1" * 32,
        status="applied",
        payloadHash="2" * 64,
        atMs=1_000_001,
    )
    with pytest.raises(ApiError, match="comfort_audit_limit"):
        audit.append(
            kind="result",
            policyId=POLICY,
            policyRevision=10,
            actorAccountId=ADMIN,
            requestId="2" * 32,
            status="applied",
            payloadHash="2" * 64,
            atMs=1_000_002,
        )
