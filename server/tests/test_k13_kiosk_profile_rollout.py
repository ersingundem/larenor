import hashlib
import json
import uuid
from io import BytesIO

import pytest
from conftest import auth, ready
from larenor_server.errors import ApiError
from larenor_server.runtime import _verified_rollout_release
from test_admin import activate
from test_admin import create as create_user

SIGNER = "a" * 64


def test_rollout_catalog_requires_current_apk_readback_and_closes_stream():
    published = manifest()

    class Store:
        def __init__(self):
            self.stream = BytesIO(b"apk")
            self.checked = []

        def latest(self, channel):
            assert channel == "stable"
            return published

        def open_apk(self, version):
            self.checked.append(version)
            return published, self.stream

    store = Store()
    assert _verified_rollout_release(store, "stable") == published
    assert store.checked == [42]
    assert store.stream.closed


def test_rollout_catalog_rejects_missing_or_raced_apk():
    published = manifest()

    class Store:
        def latest(self, _channel):
            return published

        def open_apk(self, _version):
            raise ApiError("server_unavailable", 503)

    with pytest.raises(ApiError):
        _verified_rollout_release(Store(), "stable")

    class RacedStore(Store):
        def __init__(self):
            self.stream = BytesIO(b"apk")

        def open_apk(self, _version):
            return manifest(
                versionCode=43,
                downloadPath="/api/v1/client/releases/43/apk",
            ), self.stream

    raced = RacedStore()
    with pytest.raises(ApiError):
        _verified_rollout_release(raced, "stable")
    assert raced.stream.closed


def root(app):
    context = app.state.core.context
    return f"/api/v1/tablet-fleet/{context.coreId}/{context.homeId}"


def manifest(**changes):
    value = {
        "schemaVersion": 1,
        "applicationId": "com.ersingundem.larenor",
        "versionCode": 42,
        "versionName": "1.2.3",
        "certificateSha256": SIGNER,
        "apkSha256": "b" * 64,
        "sizeBytes": 1024,
        "minSdk": 26,
        "commit": "c" * 40,
        "downloadPath": "/api/v1/client/releases/42/apk",
        "publishedAt": "2026-09-21T00:00:00+00:00",
        "releaseNotes": "Verified test release",
    }
    value.update(changes)
    return value


def register(client, pair, path, *, name, client_version="1.2.3"):
    response = client.post(path + "/devices", headers=auth(pair), json={
        "schemaVersion": 1,
        "registrationId": uuid.uuid4().hex,
        "name": name,
        "platform": "android",
        "managementMode": "standard",
        "clientVersion": client_version,
        "appliedProfileRevision": 1,
    })
    assert response.status_code == 201
    return response.json()["tablet"]


def preview_body(tablets, **changes):
    body = {
        "schemaVersion": 1,
        "channel": "stable",
        "profileRevision": 2,
        "rolloutPercent": 100,
        "settings": {"fullscreen": True, "idleTimeoutSeconds": 300},
        "targets": [
            {"deviceId": tablet["ref"]["id"],
             "expectedDeviceRevision": tablet["revision"]}
            for tablet in sorted(tablets, key=lambda value: value["ref"]["id"])
        ],
    }
    body.update(changes)
    payload = [
        1,
        body["channel"],
        body["profileRevision"],
        body["rolloutPercent"],
        [body["settings"]["fullscreen"], body["settings"]["idleTimeoutSeconds"]],
        [[target["deviceId"], target["expectedDeviceRevision"]]
         for target in body["targets"]],
    ]
    body["requestDigest"] = hashlib.sha256(
        json.dumps(payload, separators=(",", ":")).encode()
    ).hexdigest()
    return body


def bind(app, value=None, signer=SIGNER):
    app.state.core.tablet_fleet.bind_release_catalog(
        lambda channel: value or manifest(), signer)


def test_dry_run_seals_exact_release_and_reports_bounded_diff_without_writes(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    bind(app)
    path = root(app)
    current = register(client, admin, path, name="Current tablet")
    old = register(client, admin, path, name="Old tablet", client_version="1.0.0")
    before = client.get(path + "/devices", headers=auth(admin)).json()
    audit_before = client.get(path + "/audit", headers=auth(admin)).json()

    request = preview_body([current, old])
    first = client.post(path + "/profiles/dry-run", headers=auth(admin), json=request)
    replay = client.post(path + "/profiles/dry-run", headers=auth(admin), json=request)

    assert first.status_code == 200 and replay.json() == first.json()
    result = first.json()
    assert result["scope"] == before["scope"]
    assert result["requestDigest"] == request["requestDigest"]
    assert result["release"] == {
        "applicationId": "com.ersingundem.larenor",
        "certificateSha256": SIGNER,
        "versionCode": 42,
        "versionName": "1.2.3",
        "apkSha256": "b" * 64,
    }
    states = {item["deviceId"]: item for item in result["devices"]}
    assert states[current["ref"]["id"]]["state"] == "ready"
    assert states[current["ref"]["id"]]["differences"] == ["profileRevision"]
    assert states[old["ref"]["id"]]["state"] == "appUpdateRequired"
    assert states[old["ref"]["id"]]["differences"] == [
        "applicationVersion", "profileRevision"]
    assert client.get(path + "/devices", headers=auth(admin)).json() == before
    assert client.get(path + "/audit", headers=auth(admin)).json() == audit_before


def test_changed_replay_stale_target_and_foreign_release_fail_closed(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    bind(app)
    path = root(app)
    tablet = register(client, admin, path, name="Wall tablet")
    request = preview_body([tablet], rolloutPercent=10)

    changed = client.post(path + "/profiles/dry-run", headers=auth(admin), json={
        **request,
        "rolloutPercent": 100,
    })
    assert changed.status_code == 409
    assert changed.json()["error"]["code"] == "tablet_rollout_replay_changed"

    stale = preview_body([tablet])
    stale["targets"][0]["expectedDeviceRevision"] += 1
    stale = preview_body([], targets=stale["targets"])
    response = client.post(path + "/profiles/dry-run", headers=auth(admin), json=stale)
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "tablet_device_changed"

    # A catalog entry signed by any certificate other than the configured
    # Larenor signer is never exposed as rollout-ready.
    app.state.core.tablet_fleet._release_catalog = lambda channel: manifest(
        certificateSha256="d" * 64
    )
    foreign = client.post(path + "/profiles/dry-run", headers=auth(admin), json=request)
    assert foreign.status_code == 503
    assert foreign.json()["error"]["code"] == "tablet_release_unavailable"


def test_admin_scope_is_required_and_rollout_percentage_only_defers(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    bind(app)
    path = root(app)
    tablets = [register(client, admin, path, name=f"Tablet {index}")
               for index in range(12)]
    body = preview_body(tablets, rolloutPercent=10)

    create_user(client, admin)
    member = activate(client, "member")
    assert client.post(path + "/profiles/dry-run", headers=auth(member), json=body).status_code == 403
    wrong_home = path.replace(app.state.core.context.homeId, "f" * 32)
    assert client.post(wrong_home + "/profiles/dry-run", headers=auth(admin), json=body).status_code == 404

    result = client.post(path + "/profiles/dry-run", headers=auth(admin), json=body)
    assert result.status_code == 200
    states = {item["state"] for item in result.json()["devices"]}
    assert states <= {"ready", "deferred"}
    assert "deferred" in states
    assert client.get(path + "/devices", headers=auth(admin)).status_code == 200


@pytest.mark.parametrize("changed", [
    {"applicationId": "other.example"},
    {"certificateSha256": "d" * 64},
    {"versionCode": 43},
    {"versionName": ""},
    {"apkSha256": "wrong"},
])
def test_foreign_or_malformed_release_never_becomes_rollout_ready(server, changed):
    app, client, _settings, _clock = server
    admin = ready(server)
    app.state.core.tablet_fleet.bind_release_catalog(
        lambda channel: manifest(**changed), SIGNER)
    path = root(app)
    tablet = register(client, admin, path, name="Test tablet")
    response = client.post(path + "/profiles/dry-run", headers=auth(admin),
                           json=preview_body([tablet]))
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "tablet_release_unavailable"
