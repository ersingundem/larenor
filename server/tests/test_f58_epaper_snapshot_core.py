import pytest

from larenor_server.epaper_snapshots import (
    EpaperAuthority,
    EpaperCardData,
    EpaperCardSlot,
    EpaperDataSnapshot,
    EpaperDeliveryAck,
    EpaperDevice,
    EpaperLayout,
    EpaperPolicy,
    EpaperSnapshotService,
)
from larenor_server.errors import ApiError


CORE = "1" * 32
HOME = "2" * 32
ACCOUNT = "3" * 32
FAMILY = "4" * 32
DEVICE = "5" * 32
LAYOUT = "6" * 32
POLICY = "7" * 32
DATA = "8" * 32
SLOT_WEATHER = "9" * 32
SLOT_ENERGY = "a" * 32


class Clock:
    def __init__(self):
        self.ms = 4_000_000

    def __call__(self):
        return self.ms


def authority(**changes):
    values = dict(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        homeRevision=3,
        accountId=ACCOUNT,
        accountRevision=5,
        memberRevision=7,
        sessionFamilyId=FAMILY,
        active=True,
        canPublishEpaper=True,
    )
    values.update(changes)
    return EpaperAuthority(**values)


def device(**changes):
    values = dict(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        deviceId=DEVICE,
        revision=11,
        bridgeRevision=13,
        width=296,
        height=128,
        supportedColors=["black", "white", "red"],
        active=True,
        connectivity="offline",
        batteryPercent=72,
        lastSeenAtMs=3_900_000,
    )
    values.update(changes)
    return EpaperDevice(**values)


def layout(**changes):
    values = dict(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        layoutId=LAYOUT,
        revision=17,
        width=296,
        height=128,
        colors=["black", "white", "red"],
        slots=[
            EpaperCardSlot(
                schemaVersion=1,
                slotId=SLOT_WEATHER,
                kind="weather",
                column=0,
                row=0,
                columnSpan=1,
                rowSpan=1,
            ),
            EpaperCardSlot(
                schemaVersion=1,
                slotId=SLOT_ENERGY,
                kind="energy",
                column=1,
                row=0,
                columnSpan=1,
                rowSpan=1,
            ),
        ],
    )
    values.update(changes)
    return EpaperLayout(**values)


def policy(**changes):
    values = dict(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        policyId=POLICY,
        revision=19,
        allowedKinds=["weather", "energy", "temperature", "clock"],
        allowedColors=["black", "white", "red"],
        maxCards=4,
        maxTtlSeconds=3_600,
        sharedContentOnly=True,
    )
    values.update(changes)
    return EpaperPolicy(**values)


def data(*, revision=23, **changes):
    values = dict(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        dataId=DATA,
        revision=revision,
        providerRevision=29,
        capturedAtMs=3_999_900,
        classification="shared",
        cards=[
            EpaperCardData(
                schemaVersion=1,
                slotId=SLOT_WEATHER,
                kind="weather",
                label="Dışarı",
                value="18",
                unit="°C",
                status="normal",
                accent="red",
            ),
            EpaperCardData(
                schemaVersion=1,
                slotId=SLOT_ENERGY,
                kind="energy",
                label="Güneş",
                value="2.4",
                unit="kW",
                status="normal",
                accent="black",
            ),
        ],
    )
    values.update(changes)
    return EpaperDataSnapshot(**values)


def service(clock=None, *, current_device=None, current_layout=None, current_data=None, current_policy=None):
    device_value = current_device or device()
    layout_value = current_layout or layout()
    data_value = current_data or data()
    policy_value = current_policy or policy()
    return EpaperSnapshotService(
        authorityResolver=lambda account_id: authority() if account_id == ACCOUNT else None,
        deviceResolver=lambda device_id: device_value if device_id == DEVICE else None,
        layoutResolver=lambda layout_id: layout_value if layout_id == LAYOUT else None,
        dataResolver=lambda data_id: data_value if data_id == DATA else None,
        policyResolver=lambda policy_id: policy_value if policy_id == POLICY else None,
        clockMs=clock or Clock(),
    )


def test_allowlisted_snapshot_is_exact_ttl_bounded_secret_free_and_deterministic():
    current_device = device()
    current_layout = layout()
    current_data = data()
    current_policy = policy()
    first = service().compose(
        authority(),
        current_device,
        current_layout,
        current_data,
        current_policy,
        ttlSeconds=900,
    )
    second = service().compose(
        authority(),
        current_device,
        current_layout,
        current_data,
        current_policy,
        ttlSeconds=900,
    )

    assert first == second
    assert first.renderDigest == second.renderDigest
    assert first.expiresAtMs == 4_900_000
    assert first.layoutRevision == 17
    assert first.dataRevision == 23
    assert first.dataProviderRevision == 29
    assert first.policyRevision == 19
    assert first.deviceRevision == 11
    assert {card.kind for card in first.cards} == {"weather", "energy"}
    assert "token" not in first.model_dump_json().lower()

    stale_inputs = [
        (current_device.model_copy(update={"revision": 99}), current_layout, current_data, current_policy),
        (current_device, current_layout.model_copy(update={"revision": 99}), current_data, current_policy),
        (current_device, current_layout, current_data.model_copy(update={"providerRevision": 99}), current_policy),
        (current_device, current_layout, current_data, current_policy.model_copy(update={"revision": 99})),
    ]
    current_service = service()
    for stale_device, stale_layout, stale_data, stale_policy in stale_inputs:
        with pytest.raises(ApiError) as error:
            current_service.compose(
                authority(),
                stale_device,
                stale_layout,
                stale_data,
                stale_policy,
                ttlSeconds=900,
            )
        assert (error.value.code, error.value.status) == (
            "revision_conflict",
            409,
        )

    raw_data = current_data.model_dump(mode="json")
    raw_data["cards"][0]["value"] = "Bearer private-token-value"
    with pytest.raises(ApiError) as secret_error:
        current_service.compose(
            authority(),
            current_device,
            current_layout,
            raw_data,
            current_policy,
            ttlSeconds=900,
        )
    assert (secret_error.value.code, secret_error.value.status) == (
        "epaper_content_rejected",
        400,
    )


def test_offline_pull_and_exact_complete_ack_are_idempotent():
    current_device = device(connectivity="offline")
    core = service(current_device=current_device)
    snapshot = core.compose(
        authority(), current_device, layout(), data(), policy(), ttlSeconds=900
    )
    first = core.pull(authority(), deviceId=DEVICE, requestId="b" * 32)
    second = core.pull(authority(), deviceId=DEVICE, requestId="b" * 32)

    assert first == second
    assert first.snapshot == snapshot
    assert first.deviceConnectivity == "offline"
    assert first.byteLength > 0
    assert first.frameCount > 0
    assert core.delivery_status(authority(), deviceId=DEVICE).status == "pending"

    ack = EpaperDeliveryAck(
        schemaVersion=1,
        requestId=first.requestId,
        coreId=CORE,
        homeId=HOME,
        deviceId=DEVICE,
        deviceRevision=11,
        layoutRevision=17,
        dataRevision=23,
        policyRevision=19,
        renderDigest=snapshot.renderDigest,
        byteLength=first.byteLength,
        frameCount=first.frameCount,
        receivedFrames=first.frameCount,
        status="complete",
    )
    accepted = core.acknowledge(authority(), ack)
    assert (accepted.status, accepted.verified) == ("verified", True)
    assert core.acknowledge(authority(), ack) == accepted
    verified = core.delivery_status(authority(), deviceId=DEVICE)
    assert (verified.status, verified.verifiedDigest) == (
        "verified",
        snapshot.renderDigest,
    )


def test_new_partial_or_expired_snapshot_never_reuses_old_verified_state():
    clock = Clock()
    current_data = [data()]
    core = EpaperSnapshotService(
        authorityResolver=lambda account_id: authority() if account_id == ACCOUNT else None,
        deviceResolver=lambda device_id: device() if device_id == DEVICE else None,
        layoutResolver=lambda layout_id: layout() if layout_id == LAYOUT else None,
        dataResolver=lambda data_id: current_data[0] if data_id == DATA else None,
        policyResolver=lambda policy_id: policy() if policy_id == POLICY else None,
        clockMs=clock,
    )
    old = core.compose(authority(), device(), layout(), current_data[0], policy(), ttlSeconds=60)
    old_pull = core.pull(authority(), deviceId=DEVICE, requestId="b" * 32)
    old_ack = EpaperDeliveryAck(
        schemaVersion=1,
        requestId=old_pull.requestId,
        coreId=CORE,
        homeId=HOME,
        deviceId=DEVICE,
        deviceRevision=11,
        layoutRevision=17,
        dataRevision=23,
        policyRevision=19,
        renderDigest=old.renderDigest,
        byteLength=old_pull.byteLength,
        frameCount=old_pull.frameCount,
        receivedFrames=old_pull.frameCount,
        status="complete",
    )
    assert core.acknowledge(authority(), old_ack).verified is True

    current_data[0] = data(revision=24)
    with pytest.raises(ApiError) as drift_error:
        core.delivery_status(authority(), deviceId=DEVICE)
    assert (drift_error.value.code, drift_error.value.status) == (
        "revision_conflict",
        409,
    )
    fresh = core.compose(
        authority(), device(), layout(), current_data[0], policy(), ttlSeconds=60
    )
    pending = core.delivery_status(authority(), deviceId=DEVICE)
    assert pending.status == "pending"
    assert pending.verifiedDigest is None
    assert fresh.renderDigest != old.renderDigest

    fresh_pull = core.pull(authority(), deviceId=DEVICE, requestId="c" * 32)
    partial_ack = EpaperDeliveryAck(
        schemaVersion=1,
        requestId=fresh_pull.requestId,
        coreId=CORE,
        homeId=HOME,
        deviceId=DEVICE,
        deviceRevision=11,
        layoutRevision=17,
        dataRevision=24,
        policyRevision=19,
        renderDigest=fresh.renderDigest,
        byteLength=fresh_pull.byteLength,
        frameCount=fresh_pull.frameCount,
        receivedFrames=fresh_pull.frameCount - 1,
        status="partial",
    )
    partial = core.acknowledge(authority(), partial_ack)
    assert (partial.status, partial.verified) == ("partial", False)
    assert core.delivery_status(authority(), deviceId=DEVICE).verifiedDigest is None

    clock.ms = fresh.expiresAtMs
    with pytest.raises(ApiError) as pull_error:
        core.pull(authority(), deviceId=DEVICE, requestId="d" * 32)
    assert (pull_error.value.code, pull_error.value.status) == (
        "epaper_snapshot_stale",
        409,
    )
    expired = core.delivery_status(authority(), deviceId=DEVICE)
    assert (expired.status, expired.verifiedDigest) == ("stale", None)
