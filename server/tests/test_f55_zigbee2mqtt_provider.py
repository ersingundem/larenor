import json
from types import SimpleNamespace

import pytest

from larenor_server.errors import ApiError
from larenor_server.mesh_center import (
    MeshAuthority,
    Zigbee2MqttObservation,
    Zigbee2MqttProvider,
    build_mesh_center_gateway,
)
from larenor_server.mesh_center.managed_ota_transport import (
    ManagedOtaInstallEvidence,
    ManagedOtaOfferEvidence,
)
from larenor_server.mesh_center.zigbee2mqtt_provider import _identity

CORE = "1" * 32
HOME = "2" * 32
ACCOUNT = "3" * 32
FAMILY = "4" * 32


def authority():
    return MeshAuthority(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        homeRevision=3,
        accountId=ACCOUNT,
        accountRevision=5,
        memberRevision=7,
        sessionFamilyId=FAMILY,
        role="admin",
        active=True,
        canObserveMesh=True,
        canUpdateMesh=True,
    )


def observation(**changes):
    values = dict(
        revision=11,
        capturedAtMs=2_000_000,
        bridgeState=b'{"state":"online"}',
        bridgeInfo=json.dumps(
            {
                "version": "2.7.1",
                "coordinator": {
                    "ieee_address": "0x00124b00120144ae",
                    "type": "zStack30x",
                    "meta": {"majorrel": 2, "minorrel": 7, "maintrel": 2},
                },
                "network": {"channel": 15, "pan_id": 5674},
            },
            separators=(",", ":"),
        ).encode(),
        devices=json.dumps(
            [
                {
                    "ieee_address": "0x00124b00120144ae",
                    "type": "Coordinator",
                    "supported": False,
                    "disabled": False,
                    "friendly_name": "Coordinator",
                    "definition": None,
                    "power_source": None,
                    "interview_state": "SUCCESSFUL",
                },
                {
                    "ieee_address": "0x90fd9ffffe6494fc",
                    "type": "Router",
                    "supported": True,
                    "disabled": False,
                    "friendly_name": "living_room/bulb",
                    "definition": {"model": "LED1624G9", "vendor": "IKEA"},
                    "power_source": "Mains (single phase)",
                    "software_build_id": "1.3.009",
                    "date_code": "20180410",
                    "interview_state": "SUCCESSFUL",
                },
            ],
            separators=(",", ":"),
        ).encode(),
        deviceStates={
            "living_room/bulb": b'{"last_seen":1999,"update":{"state":"idle"}}'
        },
        availability={"living_room/bulb": b"online"},
    )
    values.update(changes)
    return Zigbee2MqttObservation(**values)


def provider(source):
    current = authority()
    return Zigbee2MqttProvider(
        core_id=CORE,
        home_id=HOME,
        master_key=b"z" * 32,
        observe=source,
        authority_for_actor=lambda actor: current,
        authority_for_account=lambda account_id: (
            current if account_id == ACCOUNT else None
        ),
    )


def test_retained_inventory_is_projected_without_invented_route_ota_or_interference(
    tmp_path,
):
    adapter = provider(observation)
    gateway = build_mesh_center_gateway(
        adapter,
        master_key=b"m" * 32,
        data_dir=tmp_path,
        clock=lambda: 2_000,
    )
    actor = SimpleNamespace(id=ACCOUNT, family_id=FAMILY)

    snapshot = gateway.snapshot(actor, CORE, HOME)

    assert snapshot.topology.coordinator.online is True
    assert snapshot.topology.coordinator.channel == 15
    assert snapshot.topology.borderRouters == []
    assert len(snapshot.topology.devices) == 1
    device = snapshot.topology.devices[0]
    assert (device.manufacturer, device.model, device.firmwareVersion) == (
        "IKEA",
        "LED1624G9",
        "1.3.009",
    )
    assert (device.reachable, device.lastSeenAtMs) == (True, 1_999_000)
    assert (device.routeKnown, device.parentId, device.routeDepth) == (
        False,
        None,
        None,
    )
    assert snapshot.interference.channels == []
    assert snapshot.health.interferenceAvailable is False
    assert snapshot.health.channelAdvisory is None
    assert snapshot.catalog.entries == []
    assert snapshot.coordinatorBackup is None

    with pytest.raises(ApiError, match="firmware_update_unsupported"):
        adapter.install(None)


def test_offline_and_missing_device_availability_fail_closed_not_reachable():
    adapter = provider(
        lambda: observation(
            bridgeState=b'{"state":"offline"}',
            availability={},
            deviceStates={"living_room/bulb": b"{}"},
        )
    )
    actor = SimpleNamespace(id=ACCOUNT, family_id=FAMILY)
    _, topology, _, catalog, _ = adapter.snapshot(actor)

    assert topology.coordinator.online is False
    assert topology.devices[0].reachable is False
    assert topology.devices[0].lastSeenAtMs is None
    assert catalog.entries == []


def test_unknown_power_source_is_not_claimed_as_mains():
    raw = json.loads(observation().devices)
    raw[1]["power_source"] = "Unknown"
    adapter = provider(lambda: observation(devices=json.dumps(raw).encode()))

    with pytest.raises(ValueError, match="unknown_power_source"):
        adapter.snapshot(SimpleNamespace(id=ACCOUNT, family_id=FAMILY))


def test_missing_firmware_version_remains_unknown_without_hiding_device():
    raw = json.loads(observation().devices)
    raw[1].pop("software_build_id")
    adapter = provider(lambda: observation(devices=json.dumps(raw).encode()))

    _, topology, _, _, _ = adapter.snapshot(
        SimpleNamespace(id=ACCOUNT, family_id=FAMILY)
    )

    assert topology.devices[0].firmwareVersion is None


def test_provider_managed_ota_refreshes_exact_generation_before_and_after_io():
    available = observation(
        revision=12,
        deviceStates={
            "living_room/bulb": b'{"last_seen":1999,"update":{"state":"available","installed_version":5,"latest_version":10}}'
        },
    )
    complete = observation(
        revision=13,
        deviceStates={
            "living_room/bulb": b'{"last_seen":1999,"update":{"state":"idle","installed_version":10,"latest_version":10}}'
        },
    )
    observations = iter((observation(), available, complete))
    checks = []
    installs = []
    device_id = _identity("device", "0x90fd9ffffe6494fc")

    def check(target, revision):
        checks.append((target, revision))
        return ManagedOtaOfferEvidence(
            deviceId=target,
            providerRevision=12,
            installedFileVersion=5,
            latestFileVersion=10,
            sourceDigest="a" * 64,
            checkedAtMs=2_000_000,
            releaseNotesAvailable=False,
        )

    def install(target, revision, installed, latest):
        installs.append((target, revision, installed, latest))
        return ManagedOtaInstallEvidence(
            deviceId=target,
            previousProviderRevision=revision,
            providerRevision=13,
            fromFileVersion=installed,
            toFileVersion=latest,
            installedFileVersion=latest,
            progressPercent=100,
            completedAtMs=2_100_000,
        )

    adapter = Zigbee2MqttProvider(
        core_id=CORE,
        home_id=HOME,
        master_key=b"z" * 32,
        observe=lambda: next(observations),
        authority_for_actor=lambda actor: authority(),
        authority_for_account=lambda account_id: authority(),
        managed_ota_check=check,
        managed_ota_install=install,
    )
    adapter.snapshot(SimpleNamespace(id=ACCOUNT, family_id=FAMILY))

    offer = adapter.check_managed_ota(device_id, 11)
    assert offer.providerRevision == 12
    assert adapter.topology(HOME).providerRevision == 12
    readback = adapter.install_managed_ota(
        SimpleNamespace(
            deviceId=device_id,
            providerRevision=12,
            installedFileVersion=5,
            latestFileVersion=10,
        )
    )
    assert readback.providerRevision == 13
    assert adapter.topology(HOME).providerRevision == 13
    assert checks == [(device_id, 11)]
    assert installs == [(device_id, 12, 5, 10)]


@pytest.mark.parametrize(
    "change",
    [
        {"bridgeState": b'{"state":"online","state":"offline"}'},
        {"capturedAtMs": -1},
        {
            "deviceStates": {
                "living_room/bulb": b'{"last_seen":"2026-09-30T00:00:00"}'
            }
        },
    ],
)
def test_malformed_or_ambiguous_retained_evidence_is_rejected(change):
    adapter = provider(lambda: observation(**change))
    actor = SimpleNamespace(id=ACCOUNT, family_id=FAMILY)
    with pytest.raises(ValueError):
        adapter.snapshot(actor)
