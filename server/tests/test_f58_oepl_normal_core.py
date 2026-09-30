"""F58 normal Core acceptance against a real-shaped HA/OpenEPaperLink peer."""

import hashlib

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from support.f58_oepl_fixture import DEVICE, OpenEpaperLinkFixture


@pytest.fixture
def oepl():
    value = OpenEpaperLinkFixture()
    yield value
    value.close()


def provision(server, oepl):
    app, client, _settings, _clock = server
    actor = ready(server)
    service = client.post("/api/v1/admin/services", headers=auth(actor), json={
        "kind": "home_assistant", "name": "OpenEPaperLink HA",
        "baseUrl": oepl.url, "credentials": {"token": "oepl-loopback-only"},
    }).json()["service"]
    principal = app.state.core.auth.authenticate(actor["accessToken"])
    app.state.core.services.record_verification(
        principal, service["id"], service["revision"],
        state="authenticated", version="2026.9",
    )
    scope = app.state.core.context
    root = f"/api/v1/epaper/{scope.coreId}/{scope.homeId}"
    admin = f"/api/v1/admin/epaper/{scope.coreId}/{scope.homeId}"
    authority = client.get(root + "/authority", headers=auth(actor)).json()
    expected = {key: authority[key] for key in (
        "schemaVersion", "coreId", "homeId", "accountId", "sessionFamilyId",
        "homeRevision", "accountRevision", "sessionRevision",
    )}
    sources = client.post(admin + "/sources", headers=auth(actor), json=expected)
    assert sources.status_code == 200, sources.text
    source = sources.json()["devices"][0]
    mapped = client.put(admin + "/sources/" + DEVICE, headers=auth(actor), json={
        **expected, "expectedMappingRevision": 0,
        "serviceId": source["serviceId"],
        "serviceRevision": source["serviceRevision"],
        "expectedSourceRevision": source["sourceRevision"],
        "name": "Hall display", "title": "Larenor", "value": "18 °C",
        "ttlSeconds": 900,
    })
    assert mapped.status_code == 200, mapped.text
    return app, client, actor, expected, root, admin, mapped.json()


def preview(client, actor, expected, admin, mapped):
    value = client.post(
        admin + f"/devices/{DEVICE}/previews", headers=auth(actor),
        json={**expected, "expectedDeviceRevision": mapped["deviceRevision"],
              "action": "refresh"},
    )
    assert value.status_code == 201, value.text
    return value.json()


def test_actual_discovery_jpeg_preview_single_send_readback_and_lost_ack(server, oepl):
    _app, client, actor, expected, root, admin, mapped = provision(server, oepl)
    shown = preview(client, actor, expected, admin, mapped)
    assert oepl.dry_runs == 1 and oepl.real_sends == 0
    assert shown["physicalDeliveryVerified"] is False
    artifact = client.get(
        "/api/v1" + shown["artifactPath"], headers=auth(actor)
    )
    assert artifact.status_code == 200
    assert artifact.headers["content-type"] == "image/jpeg"
    assert hashlib.sha256(artifact.content).hexdigest() == shown["artifactDigest"]

    confirmed = client.post(
        admin + f"/previews/{shown['requestId']}/confirm",
        headers=auth(actor), json=expected,
    )
    assert confirmed.status_code == 200, confirmed.text
    receipt = confirmed.json()
    assert receipt["status"] == "uncertain"
    assert receipt["physicalDeliveryVerified"] is False
    assert receipt["observedSnapshotDigest"] == shown["artifactDigest"]
    assert oepl.real_sends == 1
    repeated = client.post(
        admin + f"/previews/{shown['requestId']}/confirm",
        headers=auth(actor), json=expected,
    )
    assert repeated.json() == receipt
    assert oepl.real_sends == 1

    lost = preview(client, actor, expected, admin, mapped)
    oepl.drop_real_response = True
    uncertain = client.post(
        admin + f"/previews/{lost['requestId']}/confirm",
        headers=auth(actor), json=expected,
    )
    assert uncertain.status_code == 200
    assert uncertain.json()["status"] == "uncertain"
    assert uncertain.json()["physicalDeliveryVerified"] is False
    assert oepl.real_sends == 2
    assert client.post(
        admin + f"/previews/{lost['requestId']}/confirm",
        headers=auth(actor), json=expected,
    ).status_code == 200
    assert oepl.real_sends == 2

    listed = client.post(root + "/devices", headers=auth(actor), json=expected)
    assert listed.status_code == 200
    assert listed.json()["devices"][0]["verifiedDigest"] is None


def test_registry_session_and_image_drift_fail_before_real_send(server, oepl):
    app, client, actor, expected, _root, admin, mapped = provision(server, oepl)
    shown = preview(client, actor, expected, admin, mapped)
    before = oepl.real_sends
    oepl.registry_platform = "template"
    stale = client.post(
        admin + f"/previews/{shown['requestId']}/confirm",
        headers=auth(actor), json=expected,
    )
    assert stale.status_code == 409
    assert oepl.real_sends == before

    oepl.registry_platform = "open_epaper_link"
    malformed = preview(client, actor, expected, admin, mapped)
    other = client.post("/api/v1/auth/login", json={
        "username": "admin", "password": "Synthetic new password 2026",
        "deviceName": "Other e-paper tablet",
    }).json()
    other_authority = client.get(
        admin.replace("/admin", "") + "/authority", headers=auth(other)
    ).json()
    other_expected = {key: other_authority[key] for key in (
        "schemaVersion", "coreId", "homeId", "accountId", "sessionFamilyId",
        "homeRevision", "accountRevision", "sessionRevision",
    )}
    denied = client.post(
        admin + f"/previews/{malformed['requestId']}/confirm",
        headers=auth(other), json=other_expected,
    )
    assert denied.status_code == 409
    assert client.get("/api/v1" + malformed["artifactPath"],
                      headers=auth(other)).status_code == 404
    assert oepl.real_sends == before

    # A syntactically framed but non-decodable/header-only JPEG never becomes an artifact.
    oepl.image = b"\xff\xd8\xff\xc0\x00\x11\x08\x00\x80\x01\x28\x03\x01\x11\x00\x02\x11\x00\x03\x11\x00\xff\xd9"
    rejected = client.post(
        admin + f"/devices/{DEVICE}/previews", headers=auth(actor),
        json={**expected, "expectedDeviceRevision": mapped["deviceRevision"],
              "action": "refresh"},
    )
    assert rejected.status_code == 503
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM epaper_provider_commands"
        ).fetchone()[0] == 2


def test_preview_limit_is_checked_before_provider_dry_run(server, oepl, monkeypatch):
    import larenor_server.epaper_snapshots.management as management_module

    _app, client, actor, expected, _root, admin, mapped = provision(server, oepl)
    monkeypatch.setattr(management_module, "MAX_POLLS", 0)
    rejected = client.post(
        admin + f"/devices/{DEVICE}/previews", headers=auth(actor),
        json={**expected, "expectedDeviceRevision": mapped["deviceRevision"],
              "action": "refresh"},
    )
    assert rejected.status_code == 409
    assert oepl.dry_runs == 0
    with _app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM epaper_provider_commands"
        ).fetchone()[0] == 0


def test_v1_schema_upgrade_preserves_authenticated_mapping_and_foreign_keys(server, oepl):
    app, _client, actor, expected, root, _admin, _mapped = provision(server, oepl)
    with app.state.core.db.transaction() as connection:
        connection.execute("DROP TABLE epaper_provider_commands")
        connection.execute(
            "UPDATE metadata SET value='1' WHERE key='epaper_snapshot_schema'"
        )
    with TestClient(create_app(server[2])) as restarted:
        listed = restarted.post(root + "/devices", headers=auth(actor), json=expected)
        assert listed.status_code == 200, listed.text
        assert [item["deviceId"] for item in listed.json()["devices"]] == [DEVICE]
        with restarted.app.state.core.db.connection() as connection:
            assert connection.execute("PRAGMA foreign_keys").fetchone()[0] == 1
            assert connection.execute(
                "SELECT COUNT(*) FROM epaper_provider_commands"
            ).fetchone()[0] == 0
