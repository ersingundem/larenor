from conftest import Clock, auth, bootstrap_password, login
from fastapi.testclient import TestClient
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.errors import ApiError
from larenor_server.legacy_remote import (
    RemoteAuthority,
    RemoteCatalog,
    RemoteCatalogItem,
    RemoteCommandDefinition,
    RemoteCommandProfile,
    RemoteDeliveryReceipt,
    RemoteDevice,
)

DEVICE = "5" * 32
BRIDGE = "6" * 32
PROVIDER = "7" * 32
PROFILE = "8" * 32
CODE_SET = "9" * 32
BINDING = "a" * 32
REQUEST = "b" * 32


class FakeRemoteProvider:
    def __init__(self):
        self.authority = None
        self.device = None
        self.profile = None
        self.calls = []
        self.fail = False

    def catalog(self, actor, core_id, home_id):
        self.authority = RemoteAuthority(
            schemaVersion=1,
            coreId=core_id,
            homeId=home_id,
            homeRevision=3,
            accountId=actor.id,
            accountRevision=1,
            memberRevision=1,
            sessionFamilyId=actor.family_id,
            active=True,
            canControlLegacyRemote=True,
        )
        self.device = RemoteDevice(
            schemaVersion=1,
            coreId=core_id,
            homeId=home_id,
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
        self.profile = RemoteCommandProfile(
            schemaVersion=1,
            coreId=core_id,
            homeId=home_id,
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
        return RemoteCatalog(
            schemaVersion=1,
            authority=self.authority,
            items=[
                RemoteCatalogItem(
                    schemaVersion=1,
                    name="Living room TV",
                    device=self.device,
                    profile=self.profile,
                )
            ],
        )

    def resolve_authority(self, account_id):
        if self.authority is not None and self.authority.accountId == account_id:
            return self.authority
        return None

    def resolve_device(self, device_id):
        return self.device if self.device is not None and device_id == DEVICE else None

    def resolve_profile(self, profile_id):
        return (
            self.profile if self.profile is not None and profile_id == PROFILE else None
        )

    def emit(self, command):
        self.calls.append(command)
        if self.fail:
            raise TimeoutError("private bridge detail")
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


def _settings(tmp_path):
    root = tmp_path.resolve()
    return Settings(
        root / "data",
        root / "secrets/vault.key",
        clock=Clock(),
        login_ip_limit=100,
        login_account_limit=100,
        login_global_limit=100,
    )


def _ready(client, settings):
    password = bootstrap_password(settings)
    initial = login(client, "admin", password).json()
    changed = client.post(
        "/api/v1/auth/password",
        headers=auth(initial),
        json={
            "currentPassword": password,
            "newPassword": "Synthetic new password 2026",
        },
    )
    assert changed.status_code == 200
    return changed.json()


def _preview_body(catalog):
    authority = catalog["authority"]
    item = catalog["items"][0]
    device = item["device"]
    profile = item["profile"]
    return {
        "schemaVersion": 1,
        "authority": authority,
        "requestId": REQUEST,
        "deviceId": device["deviceId"],
        "expectedDeviceRevision": device["revision"],
        "providerId": device["providerId"],
        "expectedProviderRevision": device["providerRevision"],
        "bridgeId": device["bridgeId"],
        "expectedBridgeRevision": device["bridgeRevision"],
        "profileId": profile["profileId"],
        "expectedProfileRevision": profile["revision"],
        "codeSetId": profile["codeSetId"],
        "expectedCodeSetRevision": profile["codeSetRevision"],
        "bindingId": BINDING,
        "commandKey": "power_toggle",
        "repeats": 1,
        "holdMs": 0,
    }


def _start(settings, provider):
    return create_app(settings, legacy_remote_provider=provider)


def test_registered_provider_result_survives_restart_without_replay(tmp_path):
    settings = _settings(tmp_path)
    provider = FakeRemoteProvider()
    first = _start(settings, provider)
    with TestClient(first) as client:
        pair = _ready(client, settings)
        context = first.state.core.context
        root = f"/api/v1/admin/legacy-remotes/{context.coreId}/{context.homeId}"
        catalog = client.get(root, headers=auth(pair)).json()["catalog"]
        preview = client.post(
            root + "/previews", headers=auth(pair), json=_preview_body(catalog)
        ).json()["preview"]
        confirmed = client.post(
            root + f"/previews/{REQUEST}/confirm",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "authority": catalog["authority"],
                "preview": preview,
                "confirmationToken": preview["confirmationToken"],
            },
        )
        assert confirmed.status_code == 200
        expected = confirmed.json()
    assert len(provider.calls) == 1

    second = _start(settings, provider)
    with TestClient(second) as client:
        assert client.get(root, headers=auth(pair)).status_code == 200
        assert (
            client.get(root + f"/results/{REQUEST}", headers=auth(pair)).json()
            == expected
        )
        repeated = client.post(
            root + f"/previews/{REQUEST}/confirm",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "authority": catalog["authority"],
                "preview": preview,
                "confirmationToken": preview["confirmationToken"],
            },
        )
        assert repeated.json() == expected
    assert len(provider.calls) == 1
    assert REQUEST.encode() not in settings.database_file.read_bytes()


def test_lost_ack_is_durable_and_restart_never_replays(tmp_path):
    settings = _settings(tmp_path)
    provider = FakeRemoteProvider()
    provider.fail = True
    first = _start(settings, provider)
    with TestClient(first) as client:
        pair = _ready(client, settings)
        context = first.state.core.context
        root = f"/api/v1/admin/legacy-remotes/{context.coreId}/{context.homeId}"
        catalog = client.get(root, headers=auth(pair)).json()["catalog"]
        preview = client.post(
            root + "/previews", headers=auth(pair), json=_preview_body(catalog)
        ).json()["preview"]
        result = client.post(
            root + f"/previews/{REQUEST}/confirm",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "authority": catalog["authority"],
                "preview": preview,
                "confirmationToken": preview["confirmationToken"],
            },
        ).json()["result"]
        assert (result["status"], result["reason"]) == ("uncertain", "lost_ack")

    second = _start(settings, provider)
    with TestClient(second) as client:
        assert client.get(root, headers=auth(pair)).status_code == 200
        assert (
            client.get(root + f"/results/{REQUEST}", headers=auth(pair)).json()[
                "result"
            ]
            == result
        )
    assert len(provider.calls) == 1


def test_restart_recovers_persisted_dispatch_attempt_as_uncertain_without_replay(
    tmp_path, monkeypatch
):
    settings = _settings(tmp_path)
    provider = FakeRemoteProvider()
    first = _start(settings, provider)
    with TestClient(first) as client:
        pair = _ready(client, settings)
        context = first.state.core.context
        root = f"/api/v1/admin/legacy-remotes/{context.coreId}/{context.homeId}"
        catalog = client.get(root, headers=auth(pair)).json()["catalog"]
        preview = client.post(
            root + "/previews", headers=auth(pair), json=_preview_body(catalog)
        ).json()["preview"]
        store = first.state.core.legacy_remote_gateway._manager._store
        original = store.save
        saves = 0

        def fail_final_receipt(snapshot):
            nonlocal saves
            saves += 1
            if saves == 2:
                raise ApiError("remote_command_integrity_failed", 503)
            return original(snapshot)

        monkeypatch.setattr(store, "save", fail_final_receipt)
        response = client.post(
            root + f"/previews/{REQUEST}/confirm",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "authority": catalog["authority"],
                "preview": preview,
                "confirmationToken": preview["confirmationToken"],
            },
        )
        assert response.status_code == 503
    assert len(provider.calls) == 1

    second = _start(settings, provider)
    with TestClient(second) as client:
        assert client.get(root, headers=auth(pair)).status_code == 200
        recovered = client.get(root + f"/results/{REQUEST}", headers=auth(pair))
        assert recovered.status_code == 200
        assert (
            recovered.json()["result"]["status"],
            recovered.json()["result"]["reason"],
        ) == ("uncertain", "lost_ack")
    assert len(provider.calls) == 1
