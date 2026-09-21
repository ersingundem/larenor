import pytest

from larenor_server.camera_visual_sensors import (
    CameraVisualAuthority,
    Detection,
    DetectionBatch,
    EvidenceDescriptor,
    VisualSensorEngine,
    VisualSensorRule,
)
from larenor_server.errors import ApiError


CORE = "1" * 32
HOME = "2" * 32
ACCOUNT = "3" * 32
SESSION = "4" * 32
CAMERA = "5" * 32
RULE = "6" * 32
PIPELINE = "7" * 32
MODEL = "8" * 32


def authority(*, home_revision=4, member_revision=3, active=True):
    return CameraVisualAuthority(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        homeRevision=home_revision,
        accountId=ACCOUNT,
        accountRevision=8,
        memberRevision=member_revision,
        sessionFamilyId=SESSION,
        role="admin",
        accessibleCameraIds=[CAMERA],
        active=active,
        canManageVisualSensors=True,
    )


def rule(*, revision=2):
    return VisualSensorRule(
        schemaVersion=1,
        ruleId=RULE,
        ruleRevision=revision,
        cameraId=CAMERA,
        pipelineId=PIPELINE,
        pipelineRevision=5,
        modelId=MODEL,
        modelRevision=9,
        label="person",
        minimumConfidenceBps=8500,
        holdForMs=2_000,
        clearAfterMs=3_000,
        evidenceRetentionMs=60_000,
        enabled=True,
    )


def batch(request_id, captured_at, *, confidence=9000, status="ready", detections=None):
    detections = (
        [Detection(schemaVersion=1, label="person", confidenceBps=confidence, count=1)]
        if detections is None
        else detections
    )
    return DetectionBatch(
        schemaVersion=1,
        requestId=request_id,
        coreId=CORE,
        homeId=HOME,
        homeRevision=4,
        cameraId=CAMERA,
        captureRevision=captured_at // 1000 + 1,
        pipelineId=PIPELINE,
        pipelineRevision=5,
        modelId=MODEL,
        modelRevision=9,
        capturedAtMs=captured_at,
        providerStatus=status,
        evidence=EvidenceDescriptor(
            schemaVersion=1,
            digest="a" * 64,
            byteLength=120_000,
            mediaType="image/jpeg",
            expiresAtMs=captured_at + 60_000,
        ),
        detections=detections,
    )


def engine(*, current=None, current_rule=None):
    current = current or {ACCOUNT: authority()}
    current_rule = current_rule or {RULE: rule()}
    return VisualSensorEngine(
        authorityResolver=lambda account_id: current.get(account_id),
        ruleResolver=lambda rule_id: current_rule.get(rule_id),
        auditKey=b"k" * 32,
    )


def test_exact_authority_hysteresis_and_verified_automation_projection():
    service = engine()
    first = service.ingest(authority(), rule(), batch("9" * 32, 10_000))
    assert first.state == "off"
    assert first.transition == "holding_on"
    assert first.automationEligible is False

    active = service.ingest(authority(), rule(), batch("a" * 32, 12_100))
    assert active.state == "on"
    assert active.transition == "activated"
    assert active.automationEligible is True
    assert active.sequence == 2
    assert active.evidenceDigest == "a" * 64

    holding = service.ingest(
        authority(), rule(),
        batch("b" * 32, 13_000, detections=[]),
    )
    assert holding.state == "on"
    assert holding.transition == "holding_off"
    assert holding.automationEligible is False
    cleared = service.ingest(
        authority(), rule(),
        batch("c" * 32, 16_100, detections=[]),
    )
    assert cleared.state == "off"
    assert cleared.transition == "cleared"
    assert cleared.automationEligible is True


def test_degraded_provider_privacy_and_live_authority_fail_closed():
    current = {ACCOUNT: authority()}
    service = engine(current=current)
    degraded = service.ingest(
        authority(), rule(), batch("d" * 32, 20_000, status="degraded"),
    )
    assert degraded.state == "unknown"
    assert degraded.transition == "provider_degraded"
    assert degraded.automationEligible is False
    exported = service.export(authority(), RULE)
    assert exported["status"] == "degraded"
    encoded = str(exported)
    for forbidden in ("sessionFamilyId", "auditKey", "image/jpeg", "boundingBox", "raw"):
        assert forbidden not in encoded

    continuity = engine()
    continuity.ingest(authority(), rule(), batch("7" * 32, 1_000))
    continuity.ingest(
        authority(), rule(), batch("8" * 32, 2_000, status="degraded"),
    )
    resumed = continuity.ingest(authority(), rule(), batch("9" * 32, 4_000))
    assert resumed.transition == "holding_on"
    assert resumed.state == "off"
    assert resumed.automationEligible is False

    current[ACCOUNT] = authority(member_revision=4)
    with pytest.raises(ApiError, match="revision_conflict"):
        service.ingest(authority(), rule(), batch("e" * 32, 21_000))
    assert service.eventCount == 1

    with pytest.raises(ValueError):
        DetectionBatch.model_validate(
            {**batch("f" * 32, 22_000).model_dump(), "rawImage": "private"}
        )
    with pytest.raises(ValueError):
        Detection.model_validate(
            {"schemaVersion": 1, "label": "person", "confidenceBps": 9000,
             "count": 1, "boundingBox": [0, 0, 1, 1]}
        )


def test_replay_order_rule_and_audit_integrity_are_fail_closed():
    rules = {RULE: rule()}
    service = engine(current_rule=rules)
    original = batch("f" * 32, 30_000)
    accepted = service.ingest(authority(), rule(), original)
    assert service.ingest(authority(), rule(), original) == accepted
    assert service.eventCount == 1

    changed = original.model_copy(
        update={"detections": [Detection(
            schemaVersion=1, label="person", confidenceBps=9500, count=1,
        )]},
    )
    with pytest.raises(ApiError, match="idempotency_conflict"):
        service.ingest(authority(), rule(), changed)
    with pytest.raises(ApiError, match="revision_conflict"):
        service.ingest(authority(), rule(), batch("0" * 32, 29_000))

    rules[RULE] = rule(revision=3)
    with pytest.raises(ApiError, match="revision_conflict"):
        service.ingest(authority(), rule(), batch("1" * 32, 31_000))
    assert service.verifyAudit() is True
    service._events[0]["transition"] = "activated"
    assert service.verifyAudit() is False


def test_contract_bounds_reject_unsafe_labels_expired_evidence_and_unknown_camera():
    with pytest.raises(ValueError):
        Detection(schemaVersion=1, label="person\nprivate", confidenceBps=9000, count=1)
    with pytest.raises(ValueError):
        VisualSensorRule.model_validate(
            {**rule().model_dump(), "minimumConfidenceBps": 0}
        )
    with pytest.raises(ValueError):
        VisualSensorRule.model_validate(
            {**rule().model_dump(), "evidenceRetentionMs": 86_400_001}
        )

    service = engine()
    expired = batch("2" * 32, 40_000).model_copy(
        update={"evidence": EvidenceDescriptor(
            schemaVersion=1,
            digest="b" * 64,
            byteLength=1,
            mediaType="image/jpeg",
            expiresAtMs=39_999,
        )},
    )
    with pytest.raises(ApiError, match="invalid_request"):
        service.ingest(authority(), rule(), expired)
    foreign = rule().model_copy(update={"cameraId": "0" * 32})
    with pytest.raises(ApiError, match="not_found"):
        engine(current_rule={RULE: foreign}).ingest(
            authority(), foreign, batch("3" * 32, 41_000),
        )
