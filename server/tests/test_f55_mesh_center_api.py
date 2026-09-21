from conftest import auth, ready
from larenor_server.mesh_center import (
    FirmwareUpdateManager,
    FirmwareUpdateReadback,
    MeshCenterHttpGateway,
    MeshHealthService,
)
from tests.test_f55_zigbee_thread_update_center import (
    CATALOG,
    DEVICE,
    FIRMWARE,
    KEY_ID,
    authority,
    interference,
    signed_catalog,
    signing_key,
    topology,
)

REQUEST = "d" * 32


def configured(server):
    app, client, _, _ = server
    pair = ready(server)
    context = app.state.core.context
    current_authority = authority(
        coreId=context.coreId,
        homeId=context.homeId,
        accountId=pair["user"]["id"],
        sessionFamilyId=app.state.core.auth.authenticate(pair["accessToken"]).family_id,
    )
    current_topology = topology().model_copy(
        update={
            "coreId": context.coreId,
            "homeId": context.homeId,
            "homeRevision": current_authority.homeRevision,
        }
    )
    current_interference = interference().model_copy(
        update={"coreId": context.coreId, "homeId": context.homeId}
    )
    private, public = signing_key()
    catalog = signed_catalog(private)
    calls = []

    def worker(command):
        calls.append(command)
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

    health = MeshHealthService(
        authorityResolver=lambda account_id: (
            current_authority if account_id == current_authority.accountId else None
        ),
        topologyResolver=lambda home_id: (
            current_topology if home_id == current_authority.homeId else None
        ),
        interferenceResolver=lambda home_id: (
            current_interference if home_id == current_authority.homeId else None
        ),
        clockMs=lambda: 2_000_000,
    )
    updates = FirmwareUpdateManager(
        auditKey=b"f55-http-test-audit-key-material",
        authorityResolver=lambda account_id: (
            current_authority if account_id == current_authority.accountId else None
        ),
        topologyResolver=lambda home_id: (
            current_topology if home_id == current_authority.homeId else None
        ),
        catalogResolver=lambda catalog_id: catalog if catalog_id == CATALOG else None,
        signingKeyResolver=lambda key_id: public if key_id == KEY_ID else None,
        worker=worker,
        clockMs=lambda: 2_000_000,
    )
    app.state.mesh_center_gateway = MeshCenterHttpGateway(
        health=health,
        updates=updates,
        snapshotResolver=lambda actor: (
            current_authority,
            current_topology,
            current_interference,
            catalog,
        ),
    )
    root = f"/api/v1/admin/mesh-center/{context.coreId}/{context.homeId}"
    return client, pair, root, current_authority, current_topology, catalog, calls


def test_authenticated_snapshot_preview_confirm_and_readback_are_exact(server):
    client, pair, root, current_authority, current_topology, catalog, calls = (
        configured(server)
    )
    assert client.get(root).status_code == 401
    snapshot = client.get(root, headers=auth(pair))
    assert snapshot.status_code == 200
    assert snapshot.json()["snapshot"]["health"]["readOnly"] is True

    body = {
        "schemaVersion": 1,
        "authority": current_authority.model_dump(mode="json"),
        "topology": current_topology.model_dump(mode="json"),
        "catalog": catalog.model_dump(mode="json"),
        "deviceId": DEVICE,
        "firmwareId": FIRMWARE,
        "requestId": REQUEST,
    }
    preview_response = client.post(root + "/previews", headers=auth(pair), json=body)
    assert preview_response.status_code == 201
    preview = preview_response.json()["preview"]
    confirmed = client.post(
        root + f"/previews/{REQUEST}/confirm",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "authority": current_authority.model_dump(mode="json"),
            "preview": preview,
            "confirmationToken": preview["confirmationToken"],
        },
    )
    assert confirmed.status_code == 200
    assert confirmed.json()["result"]["readbackVerified"] is True
    readback = client.get(root + f"/results/{REQUEST}", headers=auth(pair))
    assert readback.status_code == 200
    assert readback.json() == confirmed.json()
    assert len(calls) == 1


def test_provider_and_request_boundaries_fail_closed(server):
    app, client, _, _ = server
    pair = ready(server)
    context = app.state.core.context
    root = f"/api/v1/admin/mesh-center/{context.coreId}/{context.homeId}"
    unavailable = client.get(root, headers=auth(pair))
    assert unavailable.status_code == 503
    assert unavailable.json()["error"]["code"] == "mesh_provider_unavailable"
    duplicate = client.get(
        root,
        headers=[
            ("Authorization", "Bearer " + pair["accessToken"]),
            ("Authorization", "Bearer " + pair["accessToken"]),
        ],
    )
    assert duplicate.status_code == 400
    assert client.get(root + "?probe=1", headers=auth(pair)).status_code == 400


def test_snapshot_rejects_catalog_without_the_exact_vendor_signature(server):
    client, pair, root, *_ = configured(server)
    gateway = client.app.state.mesh_center_gateway
    original = gateway._resolve_snapshot
    tampered = lambda actor: (
        lambda authority, topology, interference, catalog: (
            authority,
            topology,
            interference,
            catalog.model_copy(update={"signature": "0" * 128}),
        )
    )(*original(actor))
    gateway._resolve_snapshot = tampered
    gateway._updates._resolve_catalog = lambda _catalog_id: tampered(None)[3]
    response = client.get(root, headers=auth(pair))
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "firmware_signature_invalid"
