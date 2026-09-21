from dataclasses import replace

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from larenor_server.errors import ApiError
from larenor_server.mesh_center import (
    BorderRouterNode,
    ChannelObservation,
    CoordinatorNode,
    FirmwareCatalog,
    FirmwareCatalogEntry,
    FirmwareUpdateManager,
    FirmwareUpdateReadback,
    InterferenceSnapshot,
    MeshAuthority,
    MeshDevice,
    MeshHealthService,
    MeshTopology,
    firmware_catalog_payload,
)


CORE = "1" * 32
HOME = "2" * 32
ACCOUNT = "3" * 32
FAMILY = "4" * 32
COORDINATOR = "5" * 32
ROUTER = "6" * 32
DEVICE = "7" * 32
THREAD_DEVICE = "8" * 32
CATALOG = "9" * 32
FIRMWARE = "a" * 32
KEY_ID = "b" * 32
DIGEST = "c" * 64


class Clock:
    def __init__(self):
        self.ms = 2_000_000

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
        role="admin",
        active=True,
        canObserveMesh=True,
        canUpdateMesh=True,
    )
    values.update(changes)
    return MeshAuthority(**values)


def zigbee_device(**changes):
    values = dict(
        schemaVersion=1,
        deviceId=DEVICE,
        revision=13,
        providerRevision=17,
        routeRevision=19,
        protocol="zigbee",
        manufacturer="Acme",
        model="Lamp-A",
        hardwareRevision="hw-1",
        firmwareVersion="1.2.0",
        powerSource="mains",
        batteryPercent=None,
        reachable=True,
        updating=False,
        parentId=COORDINATOR,
        routeDepth=1,
        lastSeenAtMs=1_999_900,
    )
    values.update(changes)
    return MeshDevice(**values)


def topology(*, devices=None, **changes):
    values = dict(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        homeRevision=3,
        revision=11,
        providerRevision=12,
        capturedAtMs=1_999_900,
        coordinator=CoordinatorNode(
            schemaVersion=1,
            nodeId=COORDINATOR,
            revision=5,
            providerRevision=6,
            protocol="zigbee",
            channel=20,
            firmwareVersion="3.1.0",
            online=True,
        ),
        borderRouters=[
            BorderRouterNode(
                schemaVersion=1,
                nodeId=ROUTER,
                revision=7,
                providerRevision=8,
                routeRevision=9,
                protocol="thread",
                firmwareVersion="2.0.0",
                online=True,
            )
        ],
        devices=devices
        or [
            zigbee_device(),
            zigbee_device(
                deviceId=THREAD_DEVICE,
                protocol="thread",
                parentId=ROUTER,
                powerSource="battery",
                batteryPercent=18,
            ),
        ],
    )
    values.update(changes)
    return MeshTopology(**values)


def interference(**changes):
    values = dict(
        schemaVersion=1,
        coreId=CORE,
        homeId=HOME,
        revision=23,
        providerRevision=29,
        capturedAtMs=1_999_900,
        channels=[
            ChannelObservation(channel=11, utilizationPercent=70, energyDbm=-55),
            ChannelObservation(channel=15, utilizationPercent=12, energyDbm=-91),
            ChannelObservation(channel=20, utilizationPercent=86, energyDbm=-48),
            ChannelObservation(channel=25, utilizationPercent=28, energyDbm=-82),
        ],
    )
    values.update(changes)
    return InterferenceSnapshot(**values)


def signing_key():
    private = Ed25519PrivateKey.generate()
    public = private.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return private, public


def signed_catalog(private, *, entries=None, **changes):
    values = dict(
        schemaVersion=1,
        catalogId=CATALOG,
        revision=31,
        providerRevision=37,
        generatedAtMs=1_999_000,
        expiresAtMs=2_600_000,
        signingKeyId=KEY_ID,
        entries=entries
        or [
            FirmwareCatalogEntry(
                schemaVersion=1,
                firmwareId=FIRMWARE,
                protocol="zigbee",
                manufacturer="Acme",
                model="Lamp-A",
                compatibleHardwareRevisions=["hw-1"],
                sourceVersions=["1.2.0"],
                version="1.3.0",
                sha256=DIGEST,
                sizeBytes=524_288,
                minimumBatteryPercent=50,
                requiresMains=False,
            )
        ],
        signature="0" * 128,
    )
    values.update(changes)
    unsigned = FirmwareCatalog(**values)
    return unsigned.model_copy(
        update={"signature": private.sign(firmware_catalog_payload(unsigned)).hex()}
    )


def health_service(current_topology, current_interference):
    return MeshHealthService(
        authorityResolver=lambda account_id: authority() if account_id == ACCOUNT else None,
        topologyResolver=lambda home_id: current_topology if home_id == HOME else None,
        interferenceResolver=lambda home_id: (
            current_interference if home_id == HOME else None
        ),
        clockMs=Clock(),
    )


def update_manager(current_topology, catalog, public_key, worker, clock=None):
    return FirmwareUpdateManager(
        auditKey=b"f55-zigbee-thread-update-audit-key",
        authorityResolver=lambda account_id: authority() if account_id == ACCOUNT else None,
        topologyResolver=lambda home_id: current_topology if home_id == HOME else None,
        catalogResolver=lambda catalog_id: catalog if catalog_id == CATALOG else None,
        signingKeyResolver=lambda key_id: public_key if key_id == KEY_ID else None,
        worker=worker,
        clockMs=clock or Clock(),
    )


def test_exact_topology_health_is_read_only_and_channel_changes_are_advisory():
    current_topology = topology()
    current_interference = interference()
    report = health_service(current_topology, current_interference).observe(
        authority(), current_topology, current_interference
    )

    assert report.readOnly is True
    assert report.channelAdvisory.advisory is True
    assert report.channelAdvisory.currentChannel == 20
    assert report.channelAdvisory.recommendedChannel == 15
    assert report.channelAdvisory.applied is False
    assert report.status == "degraded"
    assert report.lowBatteryDeviceIds == [THREAD_DEVICE]
    assert report.threadBorderRouterCount == 1

    stale_topologies = [
        current_topology.model_copy(update={"revision": 99}),
        current_topology.model_copy(
            update={
                "coordinator": current_topology.coordinator.model_copy(
                    update={"revision": 99}
                )
            }
        ),
        current_topology.model_copy(
            update={
                "borderRouters": [
                    current_topology.borderRouters[0].model_copy(
                        update={"routeRevision": 99}
                    )
                ]
            }
        ),
        current_topology.model_copy(
            update={
                "devices": [
                    current_topology.devices[0].model_copy(update={"revision": 99}),
                    current_topology.devices[1],
                ]
            }
        ),
    ]
    for stale_topology in stale_topologies:
        with pytest.raises(ApiError) as topology_error:
            health_service(current_topology, current_interference).observe(
                authority(), stale_topology, current_interference
            )
        assert (topology_error.value.code, topology_error.value.status) == (
            "revision_conflict",
            409,
        )

    stale_interference = current_interference.model_copy(update={"revision": 99})
    with pytest.raises(ApiError) as interference_error:
        health_service(current_topology, current_interference).observe(
            authority(), current_topology, stale_interference
        )
    assert (interference_error.value.code, interference_error.value.status) == (
        "revision_conflict",
        409,
    )


def test_signed_firmware_compatibility_power_and_route_safety_fail_closed():
    private, public = signing_key()
    current_topology = topology()
    catalog = signed_catalog(private)
    manager = update_manager(current_topology, catalog, public, lambda command: None)
    preview = manager.preview(
        authority(),
        current_topology,
        catalog,
        deviceId=DEVICE,
        firmwareId=FIRMWARE,
        requestId="d" * 32,
    )
    assert preview.targetVersion == "1.3.0"
    assert preview.firmwareSha256 == DIGEST
    assert preview.expectedRouteRevision == 19

    tampered = catalog.model_copy(
        update={
            "entries": [catalog.entries[0].model_copy(update={"sha256": "e" * 64})]
        }
    )
    with pytest.raises(ApiError) as signature_error:
        update_manager(current_topology, tampered, public, lambda command: None).preview(
            authority(),
            current_topology,
            tampered,
            deviceId=DEVICE,
            firmwareId=FIRMWARE,
            requestId="e" * 32,
        )
    assert (signature_error.value.code, signature_error.value.status) == (
        "firmware_signature_invalid",
        409,
    )

    stale_catalog = catalog.model_copy(update={"revision": 99})
    with pytest.raises(ApiError) as catalog_error:
        manager.preview(
            authority(),
            current_topology,
            stale_catalog,
            deviceId=DEVICE,
            firmwareId=FIRMWARE,
            requestId="1" * 32,
        )
    assert (catalog_error.value.code, catalog_error.value.status) == (
        "revision_conflict",
        409,
    )

    incompatible_entry = catalog.entries[0].model_copy(
        update={"sourceVersions": ["1.1.0"]}
    )
    incompatible = signed_catalog(private, entries=[incompatible_entry])
    with pytest.raises(ApiError) as compatibility_error:
        update_manager(
            current_topology, incompatible, public, lambda command: None
        ).preview(
            authority(),
            current_topology,
            incompatible,
            deviceId=DEVICE,
            firmwareId=FIRMWARE,
            requestId="2" * 32,
        )
    assert (compatibility_error.value.code, compatibility_error.value.status) == (
        "firmware_incompatible",
        409,
    )

    unsafe_device = zigbee_device(
        powerSource="battery",
        batteryPercent=25,
    )
    unsafe_topology = topology(devices=[unsafe_device])
    with pytest.raises(ApiError) as power_error:
        update_manager(unsafe_topology, catalog, public, lambda command: None).preview(
            authority(),
            unsafe_topology,
            catalog,
            deviceId=DEVICE,
            firmwareId=FIRMWARE,
            requestId="f" * 32,
        )
    assert (power_error.value.code, power_error.value.status) == (
        "firmware_update_safety_blocked",
        409,
    )

    unsafe_route = topology(devices=[zigbee_device(parentId="0" * 32)])
    with pytest.raises(ApiError) as route_error:
        update_manager(unsafe_route, catalog, public, lambda command: None).preview(
            authority(),
            unsafe_route,
            catalog,
            deviceId=DEVICE,
            firmwareId=FIRMWARE,
            requestId="3" * 32,
        )
    assert (route_error.value.code, route_error.value.status) == (
        "firmware_update_safety_blocked",
        409,
    )

    thread_topology = topology(devices=[zigbee_device(protocol="thread")])
    with pytest.raises(ApiError) as protocol_error:
        update_manager(thread_topology, catalog, public, lambda command: None).preview(
            authority(),
            thread_topology,
            catalog,
            deviceId=DEVICE,
            firmwareId=FIRMWARE,
            requestId="0" * 32,
        )
    assert (protocol_error.value.code, protocol_error.value.status) == (
        "firmware_update_unsupported",
        409,
    )


def test_preview_confirm_exact_readback_lost_ack_no_replay_and_audit_tamper():
    private, public = signing_key()
    current_topology = topology(devices=[zigbee_device()])
    catalog = signed_catalog(private)
    worker_calls = []

    def worker(command):
        worker_calls.append(command)
        return FirmwareUpdateReadback(
            schemaVersion=1,
            requestId=command.requestId,
            coreId=command.coreId,
            homeId=command.homeId,
            deviceId=command.deviceId,
            previousDeviceRevision=command.expectedDeviceRevision,
            deviceRevision=command.expectedResultRevision,
            providerRevision=command.expectedProviderRevision,
            routeRevision=command.expectedRouteRevision,
            installedVersion=command.targetVersion,
            installedSha256=command.firmwareSha256,
            status="installed",
        )

    manager = update_manager(current_topology, catalog, public, worker)
    preview = manager.preview(
        authority(),
        current_topology,
        catalog,
        deviceId=DEVICE,
        firmwareId=FIRMWARE,
        requestId="d" * 32,
    )
    result = manager.confirm(authority(), preview, preview.confirmationToken)
    assert (result.status, result.readbackVerified) == ("confirmed", True)
    assert manager.confirm(authority(), preview, preview.confirmationToken) == result
    assert len(worker_calls) == 1

    lost_calls = []

    def lost_ack(command):
        lost_calls.append(command)
        raise TimeoutError("private coordinator detail")

    lost = update_manager(current_topology, catalog, public, lost_ack)
    lost_preview = lost.preview(
        authority(),
        current_topology,
        catalog,
        deviceId=DEVICE,
        firmwareId=FIRMWARE,
        requestId="e" * 32,
    )
    uncertain = lost.confirm(
        authority(), lost_preview, lost_preview.confirmationToken
    )
    assert (uncertain.status, uncertain.reason) == ("uncertain", "lost_ack")
    assert lost.confirm(
        authority(), lost_preview, lost_preview.confirmationToken
    ) == uncertain
    assert len(lost_calls) == 1
    assert "private coordinator detail" not in uncertain.model_dump_json()

    first = lost.audit[0]
    lost._audit[0] = replace(first, entryHash="0" * 64)
    with pytest.raises(ApiError) as audit_error:
        lost.preview(
            authority(),
            current_topology,
            catalog,
            deviceId=DEVICE,
            firmwareId=FIRMWARE,
            requestId="f" * 32,
        )
    assert (audit_error.value.code, audit_error.value.status) == (
        "mesh_update_integrity_failed",
        503,
    )
    assert len(lost_calls) == 1
