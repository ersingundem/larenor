from larenor_server.legacy_remote import (
    LegacyRemoteHttpGateway,
    LegacyRemoteManager,
    RemoteAuthority,
    RemoteCatalog,
    RemoteCatalogItem,
    RemoteCommandDefinition,
    RemoteCommandProfile,
    RemoteDeliveryReceipt,
    RemoteDevice,
)

from conftest import auth, ready


DEVICE = "5" * 32
BRIDGE = "6" * 32
PROVIDER = "7" * 32
PROFILE = "8" * 32
CODE_SET = "9" * 32
BINDING = "a" * 32
REQUEST = "b" * 32


def configured(server):
    app, client, _settings, clock = server
    pair = ready(server)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    context = app.state.core.context
    authority = RemoteAuthority(
        schemaVersion=1,
        coreId=context.coreId,
        homeId=context.homeId,
        homeRevision=3,
        accountId=actor.id,
        accountRevision=5,
        memberRevision=7,
        sessionFamilyId=actor.family_id,
        active=True,
        canControlLegacyRemote=True,
    )
    device = RemoteDevice(
        schemaVersion=1,
        coreId=context.coreId,
        homeId=context.homeId,
        deviceId=DEVICE,
        revision=11,
        providerType="home_assistant",
        providerId=PROVIDER,
        providerRevision=13,
        bridgeId=BRIDGE,
        bridgeRevision=17,
        protocol="ir",
        stored=True,
        reachable=True,
        providerVerified=True,
    )
    profile = RemoteCommandProfile(
        schemaVersion=1,
        coreId=context.coreId,
        homeId=context.homeId,
        profileId=PROFILE,
        revision=19,
        deviceId=DEVICE,
        expectedDeviceRevision=11,
        providerId=PROVIDER,
        expectedProviderRevision=13,
        codeSetId=CODE_SET,
        codeSetRevision=23,
        protocol="ir",
        commands=[
            RemoteCommandDefinition(
                schemaVersion=1,
                bindingId=BINDING,
                key="power_toggle",
                maxRepeats=1,
                maxHoldMs=0,
            )
        ],
    )
    calls = []

    def worker(command):
        calls.append(command)
        return RemoteDeliveryReceipt(
            schemaVersion=1,
            requestId=command.requestId,
            coreId=command.coreId,
            homeId=command.homeId,
            providerId=command.providerId,
            providerRevision=command.providerRevision,
            bridgeId=command.bridgeId,
            bridgeRevision=command.bridgeRevision,
            deviceId=command.deviceId,
            deviceRevision=command.deviceRevision,
            profileId=command.profileId,
            profileRevision=command.profileRevision,
            codeSetId=command.codeSetId,
            codeSetRevision=command.codeSetRevision,
            bindingId=command.bindingId,
            key=command.key,
            repeats=command.repeats,
            holdMs=command.holdMs,
            status="emitted",
        )

    manager = LegacyRemoteManager(
        auditKey=b"f56-http-contract-audit-key-00001",
        authorityResolver=lambda account_id: authority if account_id == actor.id else None,
        deviceResolver=lambda device_id: device if device_id == DEVICE else None,
        profileResolver=lambda profile_id: profile if profile_id == PROFILE else None,
        worker=worker,
        clockMs=lambda: int(clock.now * 1000),
    )
    catalog = RemoteCatalog(
        schemaVersion=1,
        authority=authority,
        items=[
            RemoteCatalogItem(
                schemaVersion=1,
                name="Living room TV",
                device=device,
                profile=profile,
            )
        ],
    )
    app.state.legacy_remote_gateway = LegacyRemoteHttpGateway(
        manager=manager,
        catalogResolver=lambda current: catalog if current.id == actor.id else None,
    )
    root = f"/api/v1/admin/legacy-remotes/{context.coreId}/{context.homeId}"
    return client, pair, root, authority, device, profile, calls


def test_authenticated_catalog_preview_confirm_and_readback_are_exact(server):
    client, pair, root, authority, device, profile, calls = configured(server)
    assert client.get(root).status_code == 401
    listed = client.get(root, headers=auth(pair))
    assert listed.status_code == 200
    assert listed.json()["catalog"]["items"][0]["name"] == "Living room TV"

    body = {
        "schemaVersion": 1,
        "authority": authority.model_dump(mode="json"),
        "requestId": REQUEST,
        "deviceId": device.deviceId,
        "expectedDeviceRevision": device.revision,
        "providerId": device.providerId,
        "expectedProviderRevision": device.providerRevision,
        "bridgeId": device.bridgeId,
        "expectedBridgeRevision": device.bridgeRevision,
        "profileId": profile.profileId,
        "expectedProfileRevision": profile.revision,
        "codeSetId": profile.codeSetId,
        "expectedCodeSetRevision": profile.codeSetRevision,
        "bindingId": BINDING,
        "commandKey": "power_toggle",
        "repeats": 1,
        "holdMs": 0,
    }
    preview_response = client.post(root + "/previews", headers=auth(pair), json=body)
    assert preview_response.status_code == 201
    preview = preview_response.json()["preview"]
    confirmed = client.post(
        root + f"/previews/{REQUEST}/confirm",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "authority": authority.model_dump(mode="json"),
            "preview": preview,
            "confirmationToken": preview["confirmationToken"],
        },
    )
    assert confirmed.status_code == 200
    assert confirmed.json()["result"]["deliveryVerified"] is True
    readback = client.get(root + f"/results/{REQUEST}", headers=auth(pair))
    assert readback.status_code == 200
    assert readback.json() == confirmed.json()
    assert len(calls) == 1


def test_stale_or_foreign_routes_fail_closed_without_dispatch(server):
    client, pair, root, authority, device, profile, calls = configured(server)
    duplicate = client.get(
        root,
        headers=[
            ("Authorization", "Bearer " + pair["accessToken"]),
            ("Authorization", "Bearer " + pair["accessToken"]),
        ],
    )
    assert duplicate.status_code == 400
    stale = authority.model_copy(update={"accountRevision": 99})
    body = {
        "schemaVersion": 1,
        "authority": stale.model_dump(mode="json"),
        "requestId": REQUEST,
        "deviceId": device.deviceId,
        "expectedDeviceRevision": device.revision,
        "providerId": device.providerId,
        "expectedProviderRevision": device.providerRevision,
        "bridgeId": device.bridgeId,
        "expectedBridgeRevision": device.bridgeRevision,
        "profileId": profile.profileId,
        "expectedProfileRevision": profile.revision,
        "codeSetId": profile.codeSetId,
        "expectedCodeSetRevision": profile.codeSetRevision,
        "bindingId": BINDING,
        "commandKey": "power_toggle",
        "repeats": 1,
        "holdMs": 0,
    }
    assert client.post(root + "/previews", headers=auth(pair), json=body).status_code == 409
    foreign = root[:-32] + ("f" * 32)
    assert client.get(foreign, headers=auth(pair)).status_code == 404
    assert calls == []


def test_missing_provider_is_explicit_and_never_fakes_a_catalog(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    context = app.state.core.context
    root = f"/api/v1/admin/legacy-remotes/{context.coreId}/{context.homeId}"
    response = client.get(root, headers=auth(pair))
    assert (response.status_code, response.json()) == (
        503,
        {"error": {"code": "remote_provider_unavailable", "message": "The legacy remote provider is unavailable."}},
    )
