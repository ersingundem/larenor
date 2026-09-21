import pytest

from larenor_server.errors import ApiError
from larenor_server.room_presence import (
    PresenceAuthority,
    PresenceAutomationHandoff,
    PresencePolicy,
    RoomPresenceFusion,
    WorkerPresenceReceipt,
)


CORE = "1" * 32
HOME = "2" * 32
ACCOUNT = "3" * 32
SESSION = "4" * 32
POLICY = "5" * 32
DEVICE = "6" * 32
MODEL = "7" * 32
CONSENT = "8" * 32
ROOM_A = "9" * 32
ROOM_B = "a" * 32
AUTOMATION = "b" * 32
SOURCE = "d" * 32


def authority(*, revision=3, active=True):
    return PresenceAuthority(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        homeRevision=5,
        accountId=ACCOUNT,
        accountRevision=revision,
        sessionFamilyId=SESSION,
        active=active,
        canReadPresence=True,
        canManagePresence=True,
    )


def policy(*, revision=7, consent_revision=11, consent_active=True):
    return PresencePolicy.model_validate(
        {
            "schemaVersion": 1,
            "coreId": CORE,
            "homeId": HOME,
            "homeRevision": 5,
            "policyId": POLICY,
            "policyRevision": revision,
            "device": {
                "schemaVersion": 1,
                "coreId": CORE,
                "homeId": HOME,
                "deviceId": DEVICE,
                "deviceRevision": 9,
                "modelId": MODEL,
                "modelRevision": 4,
                "consentId": CONSENT,
                "consentRevision": consent_revision,
                "consentActive": consent_active,
                "allowAutomationHandoff": True,
            },
            "sources": [
                {
                    "schemaVersion": 1,
                    "sourceId": SOURCE,
                    "sourceKind": "ble",
                    "sourceRevision": 3,
                }
            ],
            "rooms": [
                {
                    "schemaVersion": 1,
                    "coreId": CORE,
                    "homeId": HOME,
                    "roomId": ROOM_A,
                    "roomRevision": 13,
                },
                {
                    "schemaVersion": 1,
                    "coreId": CORE,
                    "homeId": HOME,
                    "roomId": ROOM_B,
                    "roomRevision": 14,
                },
            ],
            "enterConfidencePermille": 700,
            "exitConfidencePermille": 450,
            "enterObservations": 2,
            "exitObservations": 2,
            "maxSignalAgeMs": 30_000,
            "active": True,
        }
    )


def signal(
    room_id=ROOM_A,
    *,
    room_revision=13,
    confidence=820,
    observed=1_000_000,
    observation_revision=1,
    source="ble",
    raw="ble:private-aa-bb-cc",
):
    return {
        "schemaVersion": 1,
        "coreId": CORE,
        "homeId": HOME,
        "homeRevision": 5,
        "roomId": room_id,
        "roomRevision": room_revision,
        "deviceId": DEVICE,
        "deviceRevision": 9,
        "modelId": MODEL,
        "modelRevision": 4,
        "policyId": POLICY,
        "policyRevision": 7,
        "consentId": CONSENT,
        "consentRevision": 11,
        "sourceId": SOURCE,
        "sourceKind": source,
        "sourceRevision": 3,
        "observationRevision": observation_revision,
        "rawIdentifier": raw,
        "confidencePermille": confidence,
        "observedAtMs": observed,
    }


def fusion(*, live_authority=None, live_policy=None):
    auth = live_authority or {ACCOUNT: authority()}
    policies = live_policy or {POLICY: policy()}
    return RoomPresenceFusion(
        authorityResolver=lambda account_id: auth.get(account_id),
        policyResolver=lambda policy_id: policies.get(policy_id),
    )


def present_estimate(service=None):
    service = service or fusion()
    first = service.fuse(authority(), policy(), [signal()], nowMs=1_005_000)
    second = service.fuse(
        authority(),
        policy(),
        [signal(observation_revision=2, observed=1_006_000)],
        nowMs=1_006_500,
    )
    assert first.status == "candidate"
    assert second.status == "present"
    return service, second


def test_exact_revision_hysteresis_and_public_projection_hide_radio_identity():
    service, estimate = present_estimate()
    assert estimate.roomId == ROOM_A
    assert estimate.confidencePermille == 820
    assert estimate.transitionRevision == 1
    assert estimate.advisoryOnly is True and estimate.grantsAccess is False
    public = estimate.model_dump(mode="json")
    text = str(public)
    assert "private-aa-bb-cc" not in text
    assert "rawIdentifier" not in text
    assert "history" not in text
    assert set(public) == {
        "schemaVersion",
        "estimateId",
        "coreId",
        "homeId",
        "homeRevision",
        "deviceId",
        "deviceRevision",
        "modelId",
        "modelRevision",
        "policyId",
        "policyRevision",
        "consentId",
        "consentRevision",
        "status",
        "roomId",
        "roomRevision",
        "confidencePermille",
        "observedAtMs",
        "sampleCount",
        "transitionRevision",
        "advisoryOnly",
        "grantsAccess",
    }
    assert service.private_history_size == 0
    assert "private-aa-bb-cc" not in repr(service.__dict__)


def test_stale_unknown_and_room_transition_need_fresh_hysteresis():
    service, current = present_estimate()
    stale = service.fuse(
        authority(),
        policy(),
        [signal(observed=900_000, observation_revision=3)],
        nowMs=1_010_000,
    )
    assert stale.status == "unknown" and stale.roomId is None
    assert stale.confidencePermille == 0
    first = service.fuse(
        authority(),
        policy(),
        [signal(ROOM_B, room_revision=14, observed=1_011_000, observation_revision=4)],
        nowMs=1_011_500,
    )
    second = service.fuse(
        authority(),
        policy(),
        [signal(ROOM_B, room_revision=14, observed=1_012_000, observation_revision=5)],
        nowMs=1_012_500,
    )
    assert first.status == "candidate" and first.roomId is None
    assert second.status == "present" and second.roomId == ROOM_B
    assert second.transitionRevision == current.transitionRevision + 1


@pytest.mark.parametrize(
    "changed,code",
    [
        ({"roomRevision": 99}, "revision_conflict"),
        ({"homeRevision": 99}, "revision_conflict"),
        ({"deviceRevision": 99}, "revision_conflict"),
        ({"modelRevision": 99}, "revision_conflict"),
        ({"policyRevision": 99}, "revision_conflict"),
        ({"consentRevision": 99}, "revision_conflict"),
        ({"sourceRevision": 99}, "revision_conflict"),
    ],
)
def test_scope_and_source_revisions_fail_closed(changed, code):
    value = signal() | changed
    with pytest.raises(ApiError, match=code):
        fusion().fuse(authority(), policy(), [value], nowMs=1_005_000)


def test_inactive_consent_unknown_source_and_unbounded_input_fail_closed():
    inactive = policy(consent_active=False)
    service = fusion(live_policy={POLICY: inactive})
    with pytest.raises(ApiError, match="consent_required"):
        service.fuse(authority(), inactive, [signal()], nowMs=1_005_000)
    with pytest.raises(ApiError, match="invalid_request"):
        fusion().fuse(authority(), policy(), [signal(source="wifi")], nowMs=1_005_000)
    with pytest.raises(ApiError, match="invalid_request"):
        fusion().fuse(authority(), policy(), [signal()] * 65, nowMs=1_005_000)
    with pytest.raises(ApiError, match="invalid_request"):
        fusion().fuse(authority(), policy(), [signal(confidence=1001)], nowMs=1_005_000)


def test_observation_replay_is_rejected_without_advancing_hysteresis():
    service = fusion()
    first = service.fuse(authority(), policy(), [signal()], nowMs=1_005_000)
    assert first.status == "candidate"
    with pytest.raises(ApiError, match="revision_conflict"):
        service.fuse(authority(), policy(), [signal()], nowMs=1_005_100)
    second = service.fuse(
        authority(),
        policy(),
        [signal(observation_revision=2, observed=1_005_200)],
        nowMs=1_005_300,
    )
    assert second.status == "present"


def test_fusion_instance_is_exact_scope_bound_and_replay_checkpoints_are_bounded():
    policies = {POLICY: policy()}
    service = RoomPresenceFusion(
        authorityResolver=lambda _account: authority(),
        policyResolver=lambda policy_id: policies.get(policy_id),
        maxSourceCheckpoints=1,
    )
    service.fuse(authority(), policy(), [signal()], nowMs=1_005_000)
    with pytest.raises(ApiError, match="source_checkpoint_limit"):
        service.fuse(
            authority(),
            policy(),
            [signal(raw="ble:another-private-id", observation_revision=2)],
            nowMs=1_005_100,
        )

    changed = policy(revision=8)
    policies[POLICY] = changed
    changed_signal = signal(observation_revision=2) | {"policyRevision": 8}
    with pytest.raises(ApiError, match="scope_mismatch"):
        service.fuse(authority(), changed, [changed_signal], nowMs=1_005_200)


def test_automation_handoff_requires_exact_receipt_and_is_idempotent():
    _, estimate = present_estimate()
    estimates = {estimate.estimateId: estimate}
    handoff = PresenceAutomationHandoff(
        authorityResolver=lambda _account: authority(),
        policyResolver=lambda _policy: policy(),
        estimateResolver=lambda estimate_id: estimates.get(estimate_id),
        maxReceipts=8,
    )
    calls = []

    def worker(command):
        calls.append(command.commandId)
        return WorkerPresenceReceipt(
            schemaVersion=1,
            commandId=command.commandId,
            requestId=command.requestId,
            automationId=command.automationId,
            automationRevision=command.automationRevision,
            estimateId=command.estimateId,
            transitionRevision=command.transitionRevision,
            deviceId=command.deviceId,
            roomId=command.roomId,
            accepted=True,
            observedState="present",
            readbackRevision=18,
        )

    receipt = handoff.dispatch(
        authority(),
        policy(),
        estimate,
        automationId=AUTOMATION,
        automationRevision=17,
        requestId="c" * 32,
        worker=worker,
    )
    duplicate = handoff.dispatch(
        authority(),
        policy(),
        estimate,
        automationId=AUTOMATION,
        automationRevision=17,
        requestId="c" * 32,
        worker=worker,
    )
    assert receipt == duplicate
    assert receipt.status == "verified" and receipt.verified is True
    assert len(calls) == 1


def test_lost_or_mismatched_automation_receipt_is_unknown_and_never_replayed():
    _, estimate = present_estimate()
    handoff = PresenceAutomationHandoff(
        authorityResolver=lambda _account: authority(),
        policyResolver=lambda _policy: policy(),
        estimateResolver=lambda _estimate: estimate,
        maxReceipts=8,
    )
    calls = []

    def lost(command):
        calls.append(command.commandId)
        raise TimeoutError("lost acknowledgement")

    first = handoff.dispatch(
        authority(),
        policy(),
        estimate,
        automationId=AUTOMATION,
        automationRevision=17,
        requestId="d" * 32,
        worker=lost,
    )
    again = handoff.dispatch(
        authority(),
        policy(),
        estimate,
        automationId=AUTOMATION,
        automationRevision=17,
        requestId="d" * 32,
        worker=lost,
    )
    assert first == again
    assert first.status == "unknown" and first.verified is False
    assert len(calls) == 1

    def mismatched(command):
        return WorkerPresenceReceipt(
            schemaVersion=1,
            commandId="e" * 32,
            requestId=command.requestId,
            automationId=command.automationId,
            automationRevision=command.automationRevision,
            estimateId=command.estimateId,
            transitionRevision=command.transitionRevision,
            deviceId=command.deviceId,
            roomId=command.roomId,
            accepted=True,
            observedState="present",
            readbackRevision=19,
        )

    receipt = handoff.dispatch(
        authority(),
        policy(),
        estimate,
        automationId=AUTOMATION,
        automationRevision=17,
        requestId="f" * 32,
        worker=mismatched,
    )
    assert receipt.status == "unknown" and receipt.verified is False

    def ambiguous(command):
        return WorkerPresenceReceipt(
            schemaVersion=1,
            commandId=command.commandId,
            requestId=command.requestId,
            automationId=command.automationId,
            automationRevision=command.automationRevision,
            estimateId=command.estimateId,
            transitionRevision=command.transitionRevision,
            deviceId=command.deviceId,
            roomId=command.roomId,
            accepted=True,
            observedState="unknown",
            readbackRevision=20,
        )

    receipt = handoff.dispatch(
        authority(),
        policy(),
        estimate,
        automationId=AUTOMATION,
        automationRevision=17,
        requestId="0" * 32,
        worker=ambiguous,
    )
    assert receipt.status == "unknown" and receipt.readbackRevision is None


def test_handoff_rejects_stale_policy_estimate_and_unbounded_ids_before_worker():
    _, estimate = present_estimate()
    current_policy = policy(revision=8)
    handoff = PresenceAutomationHandoff(
        authorityResolver=lambda _account: authority(),
        policyResolver=lambda _policy: current_policy,
        estimateResolver=lambda _estimate: estimate,
        maxReceipts=8,
    )
    calls = []

    def worker(command):
        calls.append(command)
        raise AssertionError("must not dispatch")

    with pytest.raises(ApiError, match="revision_conflict"):
        handoff.dispatch(
            authority(),
            current_policy,
            estimate,
            automationId=AUTOMATION,
            automationRevision=17,
            requestId="1" * 32,
            worker=worker,
        )

    safe = PresenceAutomationHandoff(
        authorityResolver=lambda _account: authority(),
        policyResolver=lambda _policy: policy(),
        estimateResolver=lambda _estimate: estimate,
        maxReceipts=8,
    )
    with pytest.raises(ApiError, match="invalid_request"):
        safe.dispatch(
            authority(),
            policy(),
            estimate,
            automationId=AUTOMATION,
            automationRevision=17,
            requestId="x" * 10_000,
            worker=worker,
        )
    assert calls == []
