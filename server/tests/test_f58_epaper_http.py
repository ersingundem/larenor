from conftest import auth, ready
from fastapi.testclient import TestClient

from larenor_server.app import create_app

DEVICE = "1" * 32
LAYOUT = "2" * 32
DATA = "3" * 32
POLICY = "4" * 32


def _authority(server, pair):
    app, client, _settings, _clock = server
    context = app.state.core.context
    response = client.get(
        f"/api/v1/epaper/{context.coreId}/{context.homeId}/authority",
        headers=auth(pair),
    )
    assert response.status_code == 200
    return context, response.json()


def _mapping(context, authority, now_ms):
    common = {"schemaVersion": 1, "coreId": context.coreId, "homeId": context.homeId}
    return {
        **authority,
        "expectedMappingRevision": 0,
        "name": "Hall display",
        "ttlSeconds": 900,
        "device": {
            **common,
            "deviceId": DEVICE,
            "revision": 7,
            "bridgeRevision": 2,
            "width": 800,
            "height": 480,
            "supportedColors": ["black", "white", "red"],
            "active": True,
            "connectivity": "online",
            "batteryPercent": 82,
            "lastSeenAtMs": now_ms,
        },
        "layout": {
            **common,
            "layoutId": LAYOUT,
            "revision": 4,
            "width": 800,
            "height": 480,
            "colors": ["black", "white", "red"],
            "slots": [{
                "schemaVersion": 1,
                "slotId": "5" * 32,
                "kind": "temperature",
                "column": 0,
                "row": 0,
                "columnSpan": 8,
                "rowSpan": 8,
            }],
        },
        "data": {
            **common,
            "dataId": DATA,
            "revision": 9,
            "providerRevision": 3,
            "capturedAtMs": now_ms,
            "classification": "shared",
            "cards": [{
                "schemaVersion": 1,
                "slotId": "5" * 32,
                "kind": "temperature",
                "label": "Hall",
                "value": "22.5",
                "unit": "C",
                "status": "normal",
                "accent": "red",
            }],
        },
        "policy": {
            **common,
            "policyId": POLICY,
            "revision": 5,
            "allowedKinds": ["temperature"],
            "allowedColors": ["black", "white", "red"],
            "maxCards": 2,
            "maxTtlSeconds": 3600,
            "sharedContentOnly": True,
        },
    }


def _authority_body(value):
    return {key: value[key] for key in (
        "schemaVersion", "coreId", "homeId", "accountId", "sessionFamilyId",
        "homeRevision", "accountRevision", "sessionRevision",
    )}


def test_persistent_mapping_authenticated_management_and_bounded_poll(server):
    _app, client, settings, clock = server
    pair = ready(server)
    context, current = _authority(server, pair)
    expected = _authority_body(current)
    mapped = client.put(
        f"/api/v1/admin/epaper/{context.coreId}/{context.homeId}/devices/{DEVICE}",
        headers=auth(pair),
        json=_mapping(context, expected, int(clock.now * 1000)),
    )
    assert mapped.status_code == 200
    assert mapped.json()["snapshotTrust"] == "pending"
    assert mapped.json()["reachable"] is True

    listed = client.post(
        f"/api/v1/epaper/{context.coreId}/{context.homeId}/devices",
        headers=auth(pair), json=expected,
    )
    assert listed.status_code == 200
    assert [item["name"] for item in listed.json()["devices"]] == ["Hall display"]
    assert "token" not in listed.text.lower()

    first = client.post(
        f"/api/v1/admin/epaper/{context.coreId}/{context.homeId}/devices/{DEVICE}/previews",
        headers=auth(pair),
        json={**expected, "expectedDeviceRevision": "7", "action": "refresh"},
    )
    assert first.status_code == 201
    cancelled = client.request(
        "DELETE",
        f"/api/v1/admin/epaper/{context.coreId}/{context.homeId}/previews/{first.json()['requestId']}",
        headers=auth(pair), json=expected,
    )
    assert cancelled.status_code == 204
    assert client.post(
        f"/api/v1/admin/epaper/{context.coreId}/{context.homeId}/previews/{first.json()['requestId']}/confirm",
        headers=auth(pair), json=expected,
    ).status_code == 409

    preview = client.post(
        f"/api/v1/admin/epaper/{context.coreId}/{context.homeId}/devices/{DEVICE}/previews",
        headers=auth(pair),
        json={**expected, "expectedDeviceRevision": "7", "action": "refresh"},
    ).json()
    published = client.post(
        f"/api/v1/admin/epaper/{context.coreId}/{context.homeId}/previews/{preview['requestId']}/confirm",
        headers=auth(pair), json=expected,
    )
    assert published.status_code == 200
    assert published.json()["status"] == "uncertain"

    poll_body = {**expected, "requestId": "6" * 32, "expectedDeviceRevision": 7}
    poll_path = f"/api/v1/epaper/{context.coreId}/{context.homeId}/devices/{DEVICE}/poll"
    pulled = client.post(poll_path, headers=auth(pair), json=poll_body)
    assert pulled.status_code == 200
    assert client.post(poll_path, headers=auth(pair), json=poll_body).json() == pulled.json()
    envelope = pulled.json()
    assert 0 < envelope["byteLength"] <= 256 * 1024
    assert 0 < envelope["frameCount"] <= 64
    snapshot = envelope["snapshot"]
    acknowledgement = {
        "schemaVersion": 1,
        "requestId": envelope["requestId"],
        "coreId": context.coreId,
        "homeId": context.homeId,
        "deviceId": DEVICE,
        "deviceRevision": 7,
        "layoutRevision": 4,
        "dataRevision": 9,
        "policyRevision": 5,
        "renderDigest": snapshot["renderDigest"],
        "byteLength": envelope["byteLength"],
        "frameCount": envelope["frameCount"],
        "receivedFrames": envelope["frameCount"],
        "status": "complete",
    }
    ack_path = f"/api/v1/epaper/{context.coreId}/{context.homeId}/devices/{DEVICE}/acknowledgements"
    accepted = client.post(
        ack_path, headers=auth(pair), json={**expected, "ack": acknowledgement},
    )
    assert accepted.status_code == 200
    assert accepted.json()["verified"] is True
    assert client.post(
        ack_path, headers=auth(pair), json={**expected, "ack": acknowledgement},
    ).json() == accepted.json()

    readback = client.post(
        f"/api/v1/epaper/{context.coreId}/{context.homeId}/devices/{DEVICE}",
        headers=auth(pair), json=expected,
    )
    assert readback.json()["snapshotTrust"] == "verified"
    assert readback.json()["verifiedDigest"] == snapshot["renderDigest"]

    # The second Core process reads the durable mapping and verified receipt.
    with TestClient(create_app(settings)) as restarted:
        login = restarted.post(
            "/api/v1/auth/login",
            json={"username": "admin", "password": "Synthetic new password 2026",
                  "deviceName": "Restart verifier"},
        ).json()
        new_authority = restarted.get(
            f"/api/v1/epaper/{context.coreId}/{context.homeId}/authority",
            headers=auth(login),
        ).json()
        after = restarted.post(
            f"/api/v1/epaper/{context.coreId}/{context.homeId}/devices",
            headers=auth(login), json=_authority_body(new_authority),
        )
        assert after.status_code == 200
        assert after.json()["devices"][0]["snapshotTrust"] == "verified"


def test_session_and_revision_drift_fail_closed_without_replay(server):
    _app, client, _settings, clock = server
    first_pair = ready(server)
    context, current = _authority(server, first_pair)
    expected = _authority_body(current)
    client.put(
        f"/api/v1/admin/epaper/{context.coreId}/{context.homeId}/devices/{DEVICE}",
        headers=auth(first_pair),
        json=_mapping(context, expected, int(clock.now * 1000)),
    )
    preview = client.post(
        f"/api/v1/admin/epaper/{context.coreId}/{context.homeId}/devices/{DEVICE}/previews",
        headers=auth(first_pair),
        json={**expected, "expectedDeviceRevision": "7", "action": "refresh"},
    ).json()

    second_pair = client.post(
        "/api/v1/auth/login",
        json={"username": "admin", "password": "Synthetic new password 2026",
              "deviceName": "Other tablet"},
    ).json()
    denied = client.post(
        f"/api/v1/admin/epaper/{context.coreId}/{context.homeId}/previews/{preview['requestId']}/confirm",
        headers=auth(second_pair), json=expected,
    )
    assert denied.status_code == 409
    # The rejected late callback did not consume the original preview.
    accepted = client.post(
        f"/api/v1/admin/epaper/{context.coreId}/{context.homeId}/previews/{preview['requestId']}/confirm",
        headers=auth(first_pair), json=expected,
    )
    assert accepted.status_code == 200
    assert accepted.json()["status"] == "uncertain"


def test_remapped_device_invalidates_old_preview_even_with_same_source_revisions(server):
    _app, client, _settings, clock = server
    pair = ready(server)
    context, current = _authority(server, pair)
    expected = _authority_body(current)
    admin_root = f"/api/v1/admin/epaper/{context.coreId}/{context.homeId}"
    first_mapping = _mapping(context, expected, int(clock.now * 1000))
    assert client.put(
        f"{admin_root}/devices/{DEVICE}", headers=auth(pair), json=first_mapping,
    ).status_code == 200
    preview = client.post(
        f"{admin_root}/devices/{DEVICE}/previews",
        headers=auth(pair),
        json={**expected, "expectedDeviceRevision": "7", "action": "refresh"},
    )
    assert preview.status_code == 201

    remapped = _mapping(context, expected, int(clock.now * 1000))
    remapped["expectedMappingRevision"] = 1
    remapped["data"]["cards"][0]["value"] = "23.0"
    assert client.put(
        f"{admin_root}/devices/{DEVICE}", headers=auth(pair), json=remapped,
    ).status_code == 200
    stale = client.post(
        f"{admin_root}/previews/{preview.json()['requestId']}/confirm",
        headers=auth(pair), json=expected,
    )
    assert stale.status_code == 409
    assert stale.json()["error"]["code"] == "revision_conflict"
