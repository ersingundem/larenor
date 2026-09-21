from dataclasses import replace

import pytest
from pydantic import ValidationError

from larenor_server.errors import ApiError
from larenor_server.sound_events import (
    AutomationReceipt,
    SoundClassifierBinding,
    SoundEventAuthority,
    SoundEventEngine,
    SoundObservation,
)


CORE = "1" * 32
HOME = "2" * 32
ACCOUNT = "3" * 32
FAMILY = "4" * 32
ROOM = "5" * 32
DEVICE = "6" * 32
MODEL = "7" * 32
DIGEST = "a" * 64


class Clock:
    def __init__(self):
        self.ms = 10_000

    def __call__(self):
        return self.ms


def authority(**changes):
    values = dict(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        homeRevision=3,
        accountId=ACCOUNT,
        accountRevision=4,
        memberRevision=5,
        sessionFamilyId=FAMILY,
        accessibleRoomIds=[ROOM],
        accessibleDeviceIds=[DEVICE],
        active=True,
        canObserve=True,
    )
    values.update(changes)
    return SoundEventAuthority(**values)


def binding(**changes):
    values = dict(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        roomId=ROOM,
        roomRevision=6,
        deviceId=DEVICE,
        deviceRevision=7,
        modelId=MODEL,
        modelRevision=8,
        providerRevision=9,
        policyRevision=10,
        consentRevision=11,
        consentGranted=True,
        retentionSeconds=60,
        triggerConfidence=0.8,
        releaseConfidence=0.5,
        consecutiveTriggerCount=2,
        dedupWindowMs=5_000,
        providerStatus="ready",
    )
    values.update(changes)
    return SoundClassifierBinding(**values)


def observation(number, *, confidence=0.9, observed_at=None, **changes):
    current = binding()
    values = dict(
        schemaVersion=1,
        observationId=f"{number:032x}",
        coreId=current.coreId,
        homeId=current.homeId,
        roomId=current.roomId,
        roomRevision=current.roomRevision,
        deviceId=current.deviceId,
        deviceRevision=current.deviceRevision,
        modelId=current.modelId,
        modelRevision=current.modelRevision,
        providerRevision=current.providerRevision,
        policyRevision=current.policyRevision,
        consentRevision=current.consentRevision,
        className="bark",
        confidence=confidence,
        observedAtMs=observed_at if observed_at is not None else 10_000 + number,
        evidenceDigest=DIGEST,
    )
    values.update(changes)
    return SoundObservation(**values)


def verified_handoff(calls):
    def handoff(trigger):
        calls.append(trigger)
        return AutomationReceipt(
            schemaVersion=1,
            eventId=trigger.eventId,
            coreId=trigger.coreId,
            homeId=trigger.homeId,
            roomRevision=trigger.roomRevision,
            deviceRevision=trigger.deviceRevision,
            modelRevision=trigger.modelRevision,
            providerRevision=trigger.providerRevision,
            policyRevision=trigger.policyRevision,
            consentRevision=trigger.consentRevision,
            auditSequence=trigger.auditSequence,
            auditHead=trigger.auditHead,
            accepted=True,
        )

    return handoff


def engine(*, current_authority=None, current_binding=None, handoff=None, clock=None):
    active_authority = current_authority or authority()
    active_binding = current_binding or binding()
    return SoundEventEngine(
        auditKey=b"audit-key-for-f45-sound-events-32b",
        authorityResolver=lambda account_id: (
            active_authority if account_id == ACCOUNT else None
        ),
        bindingResolver=lambda device_id: (
            active_binding if device_id == DEVICE else None
        ),
        automationHandoff=handoff,
        clockMs=clock or Clock(),
    )


def test_bounded_digest_only_events_require_exact_consent_scope_and_retention():
    with pytest.raises(ValidationError):
        SoundObservation.model_validate(
            {**observation(1).model_dump(), "rawAudio": "private-audio"}
        )

    denied = engine(current_binding=binding(consentGranted=False))
    with pytest.raises(ApiError) as error:
        denied.ingest(authority(), observation(1))
    assert (error.value.code, error.value.status) == ("forbidden", 403)
    assert denied.events(authority()) == ()

    for field in (
        "roomRevision",
        "deviceRevision",
        "modelRevision",
        "providerRevision",
        "policyRevision",
        "consentRevision",
    ):
        stale = engine()
        with pytest.raises(ApiError) as error:
            stale.ingest(authority(), observation(1, **{field: 99}))
        assert (error.value.code, error.value.status) == (
            "revision_conflict",
            409,
        )
    stale_authority = engine()
    with pytest.raises(ApiError) as error:
        stale_authority.ingest(authority(homeRevision=99), observation(1))
    assert (error.value.code, error.value.status) == ("revision_conflict", 409)

    clock = Clock()
    calls = []
    accepted = engine(clock=clock, handoff=verified_handoff(calls))
    accepted.ingest(authority(), observation(1))
    result = accepted.ingest(authority(), observation(2))
    assert result.status == "event"
    assert result.event.evidenceDigest == DIGEST
    assert "audio" not in result.event.model_dump_json().lower()
    assert len(accepted.events(authority())) == 1
    clock.ms += 60_002
    assert accepted.events(authority()) == ()


def test_confidence_hysteresis_dedup_and_provider_degradation_are_explicit():
    clock = Clock()
    calls = []
    detector = engine(clock=clock, handoff=verified_handoff(calls))

    assert detector.ingest(authority(), observation(1, confidence=0.79)).status == "suppressed"
    assert detector.ingest(authority(), observation(2)).status == "suppressed"
    first = detector.ingest(authority(), observation(3))
    assert first.status == "event"
    assert detector.ingest(authority(), observation(3)) == first
    assert detector.ingest(authority(), observation(4)).reason == "hysteresis_active"
    assert len(calls) == 1

    detector.ingest(authority(), observation(5, confidence=0.4))
    detector.ingest(authority(), observation(6))
    duplicate = detector.ingest(authority(), observation(7))
    assert (duplicate.status, duplicate.reason) == ("suppressed", "deduplicated")
    assert len(calls) == 1

    clock.ms += 5_001
    detector.ingest(authority(), observation(8, confidence=0.4, observed_at=15_002))
    detector.ingest(authority(), observation(9, observed_at=15_003))
    assert detector.ingest(
        authority(), observation(10, observed_at=15_004)
    ).status == "event"
    assert len(calls) == 2

    degraded_calls = []
    degraded = engine(
        current_binding=binding(providerStatus="degraded"),
        handoff=verified_handoff(degraded_calls),
    )
    result = degraded.ingest(authority(), observation(11))
    assert (result.status, result.reason) == ("degraded", "provider_unavailable")
    assert result.event is None
    assert degraded_calls == []


def test_authority_audit_and_automation_readback_fail_closed():
    calls = []

    def foreign_receipt(trigger):
        calls.append(trigger)
        return AutomationReceipt(
            schemaVersion=1,
            eventId="f" * 32,
            coreId=trigger.coreId,
            homeId=trigger.homeId,
            roomRevision=trigger.roomRevision,
            deviceRevision=trigger.deviceRevision,
            modelRevision=trigger.modelRevision,
            providerRevision=trigger.providerRevision,
            policyRevision=trigger.policyRevision,
            consentRevision=trigger.consentRevision,
            auditSequence=trigger.auditSequence,
            auditHead=trigger.auditHead,
            accepted=True,
        )

    guarded = engine(handoff=foreign_receipt)
    guarded.ingest(authority(), observation(1))
    failed = guarded.ingest(authority(), observation(2))
    assert (failed.status, failed.automationVerified) == ("degraded", False)
    assert failed.reason == "automation_unverified"
    assert len(calls) == 1

    with pytest.raises(ApiError) as error:
        guarded.events(authority(sessionFamilyId="e" * 32))
    assert (error.value.code, error.value.status) == ("revision_conflict", 409)

    first = guarded.audit[0]
    guarded._audit[0] = replace(first, entryHash="0" * 64)
    with pytest.raises(ApiError) as error:
        guarded.ingest(authority(), observation(3, confidence=0.4))
    assert (error.value.code, error.value.status) == (
        "sound_event_integrity_failed",
        503,
    )
    assert len(calls) == 1
