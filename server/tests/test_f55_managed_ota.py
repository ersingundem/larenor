import pytest

from larenor_server.errors import ApiError
from larenor_server.mesh_center.managed_ota import ManagedOtaManager
from larenor_server.mesh_center.managed_ota_store import ManagedOtaStore
from larenor_server.mesh_center.managed_ota_transport import (
    ManagedOtaInstallEvidence,
    ManagedOtaOfferEvidence,
)
from tests.test_f55_zigbee_thread_update_center import (
    ACCOUNT,
    DEVICE,
    HOME,
    authority,
    topology,
    zigbee_device,
)

KEY = b"provider-managed-ota-test-key!!" * 2
REQUEST = "e" * 32


_MAINS = object()


def _topology(provider_revision, *, revision=None, updating=False, battery=_MAINS):
    device = zigbee_device(
        providerRevision=provider_revision,
        updating=updating,
        powerSource="mains" if battery is _MAINS else "battery",
        batteryPercent=None if battery is _MAINS else battery,
    )
    return topology(
        devices=[device],
        providerRevision=provider_revision,
        revision=revision or provider_revision,
    )


class Clock:
    def __init__(self):
        self.value = 2_000_000

    def __call__(self):
        return self.value


def _manager(current, clock, *, store=None, installer=None, checks=None):
    def check(device_id, expected_revision):
        checks.append((device_id, expected_revision))
        assert expected_revision == 12
        current["topology"] = _topology(22)
        return ManagedOtaOfferEvidence(
            deviceId=DEVICE,
            providerRevision=22,
            installedFileVersion=5,
            latestFileVersion=10,
            sourceDigest="a" * 64,
            checkedAtMs=clock(),
            releaseNotesAvailable=True,
        )

    return ManagedOtaManager(
        key=KEY,
        authorityResolver=lambda account_id: (
            current["authority"] if account_id == ACCOUNT else None
        ),
        topologyResolver=lambda home_id: (
            current["topology"] if home_id == HOME else None
        ),
        checkWorker=check,
        installWorker=installer or (lambda _preview: None),
        clockMs=clock,
        stateStore=store,
    )


def _offer_and_preview(manager, current):
    offer = manager.check(current["authority"], current["topology"], DEVICE)
    preview = manager.preview(
        current["authority"], current["topology"], offer, REQUEST
    )
    return offer, preview


def test_check_preview_confirm_bind_current_authority_and_causal_readback(tmp_path):
    clock = Clock()
    current = {"authority": authority(), "topology": _topology(12)}
    checks = []
    installs = []

    def install(preview):
        installs.append(preview)
        current["topology"] = _topology(23)
        # Dispatch authorization expiry does not invalidate a running OTA.
        clock.value += 180_000
        return ManagedOtaInstallEvidence(
            deviceId=DEVICE,
            previousProviderRevision=22,
            providerRevision=23,
            fromFileVersion=5,
            toFileVersion=10,
            installedFileVersion=10,
            progressPercent=100,
            completedAtMs=clock(),
        )

    manager = _manager(
        current,
        clock,
        store=ManagedOtaStore(tmp_path / "ota.state", KEY[:32]),
        installer=install,
        checks=checks,
    )

    offer, preview = _offer_and_preview(manager, current)
    result = manager.confirm(
        current["authority"], preview, preview.confirmationToken
    )

    assert offer.provider == "zigbee2mqtt"
    assert offer.providerSourceDigest == "a" * 64
    assert offer.installedFileVersion == 5
    assert offer.latestFileVersion == 10
    assert checks == [(DEVICE, 12)]
    assert len(installs) == 1
    assert result.status == "confirmed"
    assert result.readbackVerified is True
    assert result.providerRevision == 23
    assert manager.confirm(
        current["authority"], preview, preview.confirmationToken
    ) == result
    assert len(installs) == 1


class SimulatedCrash(BaseException):
    pass


def test_restart_marks_persisted_dispatch_uncertain_and_never_resends(tmp_path):
    clock = Clock()
    current = {"authority": authority(), "topology": _topology(12)}
    path = tmp_path / "ota.state"
    calls = []

    def crash(preview):
        calls.append(preview.requestId)
        raise SimulatedCrash

    manager = _manager(
        current,
        clock,
        store=ManagedOtaStore(path, KEY[:32]),
        installer=crash,
        checks=[],
    )
    _, preview = _offer_and_preview(manager, current)
    with pytest.raises(SimulatedCrash):
        manager.confirm(current["authority"], preview, preview.confirmationToken)

    recovered = _manager(
        current,
        clock,
        store=ManagedOtaStore(path, KEY[:32]),
        installer=lambda _preview: calls.append("resent"),
        checks=[],
    )
    result = recovered.result(current["authority"], REQUEST)

    assert result.status == "uncertain"
    assert result.reason == "lost_ack"
    assert result.readbackVerified is False
    assert recovered.confirm(
        current["authority"], preview, preview.confirmationToken
    ) == result
    assert calls == [REQUEST]


@pytest.mark.parametrize("battery", [None, 69])
def test_low_or_unknown_battery_blocks_check_before_worker(battery):
    clock = Clock()
    current = {
        "authority": authority(),
        "topology": _topology(12, battery=battery),
    }
    calls = []
    manager = _manager(current, clock, checks=calls)

    with pytest.raises(ApiError) as error:
        manager.check(current["authority"], current["topology"], DEVICE)

    assert error.value.code == "firmware_update_safety_blocked"
    assert calls == []


def test_authority_or_provider_generation_change_after_check_is_rejected():
    clock = Clock()
    current = {"authority": authority(), "topology": _topology(12)}

    def changed_check(_device_id, _expected_revision):
        current["authority"] = authority(accountRevision=6)
        current["topology"] = _topology(22)
        return ManagedOtaOfferEvidence(
            deviceId=DEVICE,
            providerRevision=22,
            installedFileVersion=5,
            latestFileVersion=10,
            sourceDigest="a" * 64,
            checkedAtMs=clock(),
            releaseNotesAvailable=False,
        )

    manager = ManagedOtaManager(
        key=KEY,
        authorityResolver=lambda _account: current["authority"],
        topologyResolver=lambda _home: current["topology"],
        checkWorker=changed_check,
        installWorker=lambda _preview: None,
        clockMs=clock,
    )

    with pytest.raises(ApiError) as error:
        manager.check(authority(), _topology(12), DEVICE)

    assert error.value.code == "revision_conflict"
