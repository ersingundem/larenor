from conftest import auth

from larenor_server.mesh_center.managed_ota import (
    ManagedOtaOffer,
    ManagedOtaPreview,
    ManagedOtaResult,
)
from tests.test_f55_mesh_center_api import REQUEST, configured


class Managed:
    def __init__(self):
        self.calls = []

    def check(self, authority, topology, device_id):
        self.calls.append(("check", device_id))
        return ManagedOtaOffer(
            schemaVersion=1,
            offerId="e" * 32,
            provider="zigbee2mqtt",
            coreId=authority.coreId,
            homeId=authority.homeId,
            deviceId=device_id,
            topologyRevision=topology.revision,
            providerRevision=topology.providerRevision,
            deviceRevision=next(
                item.revision for item in topology.devices if item.deviceId == device_id
            ),
            installedFileVersion=5,
            latestFileVersion=10,
            providerSourceDigest="f" * 64,
            checkedAtMs=2_000_000,
            expiresAtMs=2_300_000,
            releaseNotesAvailable=True,
        )

    def preview(self, authority, topology, offer, request_id):
        self.calls.append(("preview", request_id))
        return ManagedOtaPreview(
            schemaVersion=1,
            requestId=request_id,
            coreId=authority.coreId,
            homeId=authority.homeId,
            homeRevision=authority.homeRevision,
            accountId=authority.accountId,
            accountRevision=authority.accountRevision,
            memberRevision=authority.memberRevision,
            sessionFamilyId=authority.sessionFamilyId,
            deviceId=offer.deviceId,
            topologyRevision=topology.revision,
            providerRevision=topology.providerRevision,
            deviceRevision=offer.deviceRevision,
            offerId=offer.offerId,
            installedFileVersion=offer.installedFileVersion,
            latestFileVersion=offer.latestFileVersion,
            providerSourceDigest=offer.providerSourceDigest,
            expiresAtMs=2_100_000,
            confirmationToken="a" * 64,
        )

    def confirm(self, authority, preview, token):
        self.calls.append(("confirm", preview.requestId, token))
        return self._result(preview)

    def result(self, authority, request_id):
        self.calls.append(("result", request_id))
        return ManagedOtaResult(
            schemaVersion=1,
            requestId=request_id,
            status="confirmed",
            reason="installed",
            readbackVerified=True,
            previousProviderRevision=12,
            providerRevision=13,
            installedFileVersion=10,
            completedAtMs=2_010_000,
        )

    @staticmethod
    def _result(preview):
        return ManagedOtaResult(
            schemaVersion=1,
            requestId=preview.requestId,
            status="confirmed",
            reason="installed",
            readbackVerified=True,
            previousProviderRevision=preview.providerRevision,
            providerRevision=preview.providerRevision + 1,
            installedFileVersion=preview.latestFileVersion,
            completedAtMs=2_010_000,
        )


def test_admin_managed_ota_routes_are_distinct_and_confirmation_bound(server):
    client, pair, root, authority, topology, _, _ = configured(server)
    managed = Managed()
    client.app.state.mesh_center_gateway._managed_ota = managed
    headers = auth(pair)

    checked = client.post(
        root + "/managed-ota/checks",
        headers=headers,
        json={
            "schemaVersion": 1,
            "authority": authority.model_dump(mode="json"),
            "topology": topology.model_dump(mode="json"),
            "deviceId": topology.devices[0].deviceId,
        },
    )
    assert checked.status_code == 200
    offer = checked.json()["offer"]
    assert offer["provider"] == "zigbee2mqtt"
    assert "url" not in offer and "image" not in offer

    previewed = client.post(
        root + "/managed-ota/previews",
        headers=headers,
        json={
            "schemaVersion": 1,
            "authority": authority.model_dump(mode="json"),
            "topology": topology.model_dump(mode="json"),
            "offer": offer,
            "requestId": REQUEST,
        },
    )
    assert previewed.status_code == 201
    preview = previewed.json()["preview"]
    confirmed = client.post(
        root + f"/managed-ota/previews/{REQUEST}/confirm",
        headers=headers,
        json={
            "schemaVersion": 1,
            "authority": authority.model_dump(mode="json"),
            "preview": preview,
            "confirmationToken": preview["confirmationToken"],
        },
    )
    assert confirmed.status_code == 200
    readback = client.get(
        root + f"/managed-ota/results/{REQUEST}", headers=headers
    )
    assert readback.status_code == 200
    assert readback.json()["result"]["readbackVerified"] is True
    assert [item[0] for item in managed.calls] == [
        "check", "preview", "confirm", "result"
    ]


def test_managed_ota_routes_fail_closed_when_provider_does_not_support_them(server):
    client, pair, root, authority, topology, _, _ = configured(server)
    response = client.post(
        root + "/managed-ota/checks",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "authority": authority.model_dump(mode="json"),
            "topology": topology.model_dump(mode="json"),
            "deviceId": topology.devices[0].deviceId,
        },
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "firmware_update_unsupported"
