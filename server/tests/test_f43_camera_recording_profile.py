import copy
from concurrent.futures import ThreadPoolExecutor
import threading
import time

import pytest

from larenor_server.camera_profiles import (
    CameraMode,
    CameraProfileAuthority,
    CameraProfileCoordinator,
    CameraProfileEngine,
    CameraProfilePolicy,
    CameraReadback,
    CameraScope,
    ManualCameraOverride,
    PresenceSignal,
    TamperEvidentCameraAudit,
    WorkerReadback,
)
from larenor_server.errors import ApiError, StartupError


CORE = "1" * 32
HOME = "2" * 32
ADMIN = "3" * 32
SESSION = "4" * 32
PROFILE = "5" * 32
CAMERA = "6" * 32
CAMERA_2 = "7" * 32
AREA = "8" * 32
SOURCE = "9" * 32
SERVICE = "a" * 32
BINDING = "b" * 32


def authority(*, account_revision=3, active=True, manage=True):
    return CameraProfileAuthority(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        homeRevision=7,
        accountId=ADMIN,
        accountRevision=account_revision,
        sessionFamilyId=SESSION,
        role="admin",
        active=active,
        canManageCameraProfiles=manage,
    )


def scope(camera=CAMERA, *, camera_revision=2, binding_revision=4):
    return CameraScope(
        schemaVersion=1,
        cameraId=camera,
        cameraRevision=camera_revision,
        areaId=AREA,
        areaRevision=6,
        serviceId=SERVICE,
        serviceRevision=8,
        bindingId=BINDING if camera == CAMERA else "c" * 32,
        bindingRevision=binding_revision,
    )


def policy(*, revision=11, cameras=None):
    return CameraProfilePolicy(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        profileId=PROFILE,
        profileRevision=revision,
        presenceSourceId=SOURCE,
        presenceSourceRevision=3,
        cameras=cameras or [scope()],
        enterDelayMs=30_000,
        exitDelayMs=10_000,
        hysteresisMs=5_000,
        presenceMaxAgeMs=120_000,
        atHomeMode=CameraMode(recording="paused", detection="disabled"),
        awayMode=CameraMode(recording="enabled", detection="enabled"),
        failSafeMode=CameraMode(recording="enabled", detection="enabled"),
        active=True,
    )


def signal(state="home", *, revision=1, observed=1_000_000, source_revision=3):
    return PresenceSignal(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        sourceId=SOURCE,
        sourceRevision=source_revision,
        signalRevision=revision,
        observedAtMs=observed,
        state=state,
    )


def engine(*, current_authority=None, current_policy=None):
    current_authority = current_authority or {ADMIN: authority()}
    current_policy = current_policy or {PROFILE: policy()}
    return CameraProfileEngine(
        authorityResolver=lambda account: current_authority.get(account),
        policyResolver=lambda profile_id: current_policy.get(profile_id),
    )


def readback(camera=CAMERA, state_revision=9, mode=None):
    target = scope(camera)
    return CameraReadback(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        camera=target,
        stateRevision=state_revision,
        mode=mode or CameraMode(recording="enabled", detection="enabled"),
        observedAtMs=1_034_000,
    )


def coordinator(audit, *, current_authority=None, current_policy=None):
    current_authority = current_authority or {ADMIN: authority()}
    current_policy = current_policy or {PROFILE: policy()}
    return CameraProfileCoordinator(
        audit=audit,
        authorityResolver=lambda account: current_authority.get(account),
        policyResolver=lambda profile_id: current_policy.get(profile_id),
        maxBatches=8,
    )


def test_presence_is_not_authority_and_home_transition_waits_then_fails_safe():
    current = {ADMIN: authority(manage=False)}
    profiles = {PROFILE: policy()}
    service = engine(current_authority=current, current_policy=profiles)
    with pytest.raises(ApiError, match="forbidden"):
        service.evaluate(authority(manage=False), policy(), signal(), nowMs=1_040_000)

    current[ADMIN] = authority()
    stabilizing = service.evaluate(authority(), policy(), signal(), nowMs=1_034_999)
    assert stabilizing.reason == "presence_stabilizing"
    assert stabilizing.mode.recording == "enabled"
    assert stabilizing.mode == policy().failSafeMode

    settled = service.evaluate(authority(), policy(), signal(), nowMs=1_035_000)
    assert settled.reason == "presence_home"
    assert settled.mode == policy().atHomeMode
    assert settled.targets[0].camera == scope()

    unknown = service.evaluate(
        authority(),
        policy(),
        signal("unknown", revision=2, observed=1_050_000),
        nowMs=1_050_000,
    )
    assert unknown.reason == "presence_unknown"
    assert unknown.mode == policy().failSafeMode


def test_manual_override_is_explicit_revision_bound_and_expires_to_fail_safe():
    service = engine()
    override = ManualCameraOverride(
        schemaVersion=1,
        overrideId="d" * 32,
        coreId=CORE,
        homeId=HOME,
        profileId=PROFILE,
        expectedProfileRevision=11,
        actorAccountId=ADMIN,
        mode=CameraMode(recording="paused", detection="enabled"),
        createdAtMs=1_000_000,
        expiresAtMs=1_060_000,
    )
    active = service.evaluate(
        authority(),
        policy(),
        signal("unknown"),
        nowMs=1_050_000,
        manualOverride=override,
    )
    assert active.reason == "manual_override"
    assert active.mode == override.mode

    expired = service.evaluate(
        authority(),
        policy(),
        signal("unknown"),
        nowMs=1_060_000,
        manualOverride=override,
    )
    assert expired.reason == "manual_override_expired"
    assert expired.mode == policy().failSafeMode
    next_policy = policy(revision=12)
    next_service = engine(current_policy={PROFILE: next_policy})
    with pytest.raises(ApiError, match="revision_conflict"):
        next_service.evaluate(
            authority(), next_policy, signal(), nowMs=1_040_000, manualOverride=override
        )


def test_stale_authority_policy_presence_and_camera_scope_fail_before_decision():
    current_authority = {ADMIN: authority(account_revision=4)}
    current_policy = {PROFILE: policy(revision=12)}
    service = engine(current_authority=current_authority, current_policy=current_policy)
    with pytest.raises(ApiError, match="revision_conflict"):
        service.evaluate(authority(), policy(revision=12), signal(), nowMs=1_040_000)
    with pytest.raises(ApiError, match="revision_conflict"):
        service.evaluate(
            authority(account_revision=4), policy(), signal(), nowMs=1_040_000
        )

    current = policy(cameras=[scope(), scope(CAMERA_2)])
    service = engine(
        current_authority={ADMIN: authority()}, current_policy={PROFILE: current}
    )
    with pytest.raises(ApiError, match="revision_conflict"):
        service.evaluate(
            authority(), current, signal(source_revision=2), nowMs=1_040_000
        )
    with pytest.raises(ApiError, match="revision_conflict"):
        service.evaluate(
            authority(),
            current.model_copy(
                update={"cameras": [scope(camera_revision=3), scope(CAMERA_2)]}
            ),
            signal(),
            nowMs=1_040_000,
        )


def test_worker_boundary_requires_exact_readback_and_exposes_partial_unknown_without_replay():
    p = policy(cameras=[scope(), scope(CAMERA_2)])
    service = engine(current_policy={PROFILE: p})
    decision = service.evaluate(authority(), p, signal(), nowMs=1_035_000)
    audit = TamperEvidentCameraAudit(key=b"a" * 32, coreId=CORE, homeId=HOME)
    coordinator_service = coordinator(audit, current_policy={PROFILE: p})
    calls = []

    def worker(command):
        calls.append(command.camera.cameraId)
        if command.camera.cameraId == CAMERA_2:
            raise TimeoutError("lost ack")
        return WorkerReadback(
            schemaVersion=1,
            commandId=command.commandId,
            camera=command.camera,
            stateRevision=command.expectedStateRevision + 1,
            mode=command.desiredMode,
            observedAtMs=1_036_000,
        )

    receipt = coordinator_service.apply(
        authority(),
        decision,
        [readback(), readback(CAMERA_2)],
        requestId="e" * 32,
        nowMs=1_035_000,
        worker=worker,
    )
    assert [item.status for item in receipt.results] == ["applied", "unknown"]
    assert receipt.status == "partial"
    assert receipt.results[1].code == "worker_ack_unknown"
    assert receipt.results[1].readback is None

    replay = coordinator_service.apply(
        authority(),
        decision,
        [readback(), readback(CAMERA_2)],
        requestId="e" * 32,
        nowMs=1_035_000,
        worker=worker,
    )
    assert replay == receipt
    assert calls == [CAMERA, CAMERA_2]


def test_matching_readback_skips_provider_and_mismatched_result_is_not_success():
    service = engine()
    decision = service.evaluate(authority(), policy(), signal(), nowMs=1_035_000)
    audit = TamperEvidentCameraAudit(key=b"a" * 32, coreId=CORE, homeId=HOME)
    coordinator_service = coordinator(audit)
    called = []

    skipped = coordinator_service.apply(
        authority(),
        decision,
        [readback(mode=policy().atHomeMode)],
        requestId="0" * 32,
        nowMs=1_035_000,
        worker=lambda command: called.append(command),
    )
    assert skipped.status == "already_applied" and called == []

    def wrong(command):
        return WorkerReadback(
            schemaVersion=1,
            commandId=command.commandId,
            camera=command.camera,
            stateRevision=command.expectedStateRevision + 1,
            mode=CameraMode(recording="enabled", detection="enabled"),
            observedAtMs=1_036_000,
        )

    failed = coordinator_service.apply(
        authority(),
        decision,
        [readback()],
        requestId="f" * 32,
        nowMs=1_035_000,
        worker=wrong,
    )
    assert failed.status == "failed"
    assert failed.results[0].status == "failed"
    assert failed.results[0].code == "readback_mismatch"


def test_audit_export_detects_payload_chain_and_head_tampering_and_is_bounded():
    audit = TamperEvidentCameraAudit(
        key=b"a" * 32, coreId=CORE, homeId=HOME, maxEvents=8
    )
    audit.append(
        kind="decision",
        profileId=PROFILE,
        profileRevision=11,
        actorAccountId=ADMIN,
        requestId="e" * 32,
        status="planned",
        payloadHash="1" * 64,
        atMs=1_000_000,
    )
    exported = audit.export()
    restored = TamperEvidentCameraAudit.restore(
        exported, key=b"a" * 32, coreId=CORE, homeId=HOME, maxEvents=8
    )
    assert restored.events()[0].status == "planned"

    for field, value in (("status", "applied"), ("entryHash", "0" * 64)):
        changed = copy.deepcopy(exported)
        changed["events"][0][field] = value
        with pytest.raises(StartupError, match="camera_profile_audit_invalid"):
            TamperEvidentCameraAudit.restore(
                changed, key=b"a" * 32, coreId=CORE, homeId=HOME, maxEvents=8
            )
    changed = copy.deepcopy(exported)
    changed["headTag"] = "0" * 64
    with pytest.raises(StartupError, match="camera_profile_audit_invalid"):
        TamperEvidentCameraAudit.restore(
            changed, key=b"a" * 32, coreId=CORE, homeId=HOME, maxEvents=8
        )

    for index in range(7):
        audit.append(
            kind="result",
            profileId=PROFILE,
            profileRevision=11,
            actorAccountId=ADMIN,
            requestId=f"{index + 1:032x}",
            status="applied",
            payloadHash="2" * 64,
            atMs=1_000_001 + index,
        )
    with pytest.raises(ApiError, match="camera_profile_audit_limit"):
        audit.append(
            kind="result",
            profileId=PROFILE,
            profileRevision=11,
            actorAccountId=ADMIN,
            requestId="f" * 32,
            status="applied",
            payloadHash="2" * 64,
            atMs=1_000_009,
        )


def test_concurrent_duplicate_dispatches_once_and_live_revision_changes_fail_closed():
    current_authority = {ADMIN: authority()}
    current_policy = {PROFILE: policy()}
    decision = engine(
        current_authority=current_authority, current_policy=current_policy
    ).evaluate(
        authority(),
        policy(),
        signal(),
        nowMs=1_035_000,
    )
    audit = TamperEvidentCameraAudit(key=b"a" * 32, coreId=CORE, homeId=HOME)
    service = coordinator(
        audit,
        current_authority=current_authority,
        current_policy=current_policy,
    )
    start = threading.Barrier(2)
    calls = []

    def apply_once():
        start.wait()
        return service.apply(
            authority(),
            decision,
            [readback()],
            requestId="a" * 32,
            nowMs=1_035_000,
            worker=lambda command: (
                calls.append(command.commandId),
                time.sleep(0.02),
                WorkerReadback(
                    schemaVersion=1,
                    commandId=command.commandId,
                    camera=command.camera,
                    stateRevision=command.expectedStateRevision + 1,
                    mode=command.desiredMode,
                    observedAtMs=1_036_000,
                ),
            )[-1],
        )

    with ThreadPoolExecutor(max_workers=2) as pool:
        receipts = list(pool.map(lambda _index: apply_once(), range(2)))
    assert receipts[0] == receipts[1]
    assert len(calls) == 1

    current_authority[ADMIN] = authority(account_revision=4)
    with pytest.raises(ApiError, match="revision_conflict"):
        service.apply(
            authority(),
            decision,
            [readback()],
            requestId="a" * 32,
            nowMs=1_035_000,
            worker=lambda _command: None,
        )

    current_authority[ADMIN] = authority()
    current_policy[PROFILE] = policy().model_copy(update={"enterDelayMs": 31_000})
    with pytest.raises(ApiError, match="revision_conflict"):
        service.apply(
            authority(),
            decision,
            [readback()],
            requestId="b" * 32,
            nowMs=1_035_000,
            worker=lambda _command: None,
        )
