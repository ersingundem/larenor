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
