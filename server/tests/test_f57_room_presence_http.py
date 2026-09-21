from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.room_presence import PresencePolicy

CORE = "1" * 32
HOME = "2" * 32
POLICY = "5" * 32
DEVICE = "6" * 32
MODEL = "7" * 32
CONSENT = "8" * 32
ROOM = "9" * 32
SOURCE = "d" * 32
ROUTE = "e" * 32


def _policy(context):
    return PresencePolicy.model_validate(
        {
            "schemaVersion": 1,
            "coreId": context.coreId,
            "homeId": context.homeId,
            "homeRevision": 5,
            "policyId": POLICY,
            "policyRevision": 7,
            "device": {
                "schemaVersion": 1,
                "coreId": context.coreId,
                "homeId": context.homeId,
                "deviceId": DEVICE,
                "deviceRevision": 9,
                "modelId": MODEL,
                "modelRevision": 4,
                "consentId": CONSENT,
                "consentRevision": 11,
                "consentActive": True,
                "allowAutomationHandoff": False,
            },
            "sources": [
                {
                    "schemaVersion": 1,
                    "sourceId": SOURCE,
                    "sourceKind": "ble",
                    "sourceRevision": 3,
                }
            ],
            "rooms": [
                {
                    "schemaVersion": 1,
                    "coreId": context.coreId,
                    "homeId": context.homeId,
                    "roomId": ROOM,
                    "roomRevision": 13,
                }
            ],
            "enterConfidencePermille": 700,
            "exitConfidencePermille": 450,
            "enterObservations": 2,
            "exitObservations": 2,
            "maxSignalAgeMs": 30_000,
            "active": True,
        }
    )


def _signal(context, revision, observed):
    return {
        "schemaVersion": 1,
        "coreId": context.coreId,
        "homeId": context.homeId,
        "homeRevision": 5,
        "roomId": ROOM,
        "roomRevision": 13,
        "deviceId": DEVICE,
        "deviceRevision": 9,
        "modelId": MODEL,
        "modelRevision": 4,
        "policyId": POLICY,
        "policyRevision": 7,
        "consentId": CONSENT,
        "consentRevision": 11,
        "sourceId": SOURCE,
        "sourceKind": "ble",
        "sourceRevision": 3,
        "observationRevision": revision,
        "rawIdentifier": "ble:private-aa-bb-cc",
        "confidencePermille": 880,
        "observedAtMs": observed,
    }


def _account_revision(app, account_id):
    with app.state.core.db.connection() as connection:
        return connection.execute(
            "SELECT revision FROM users WHERE id=?", (account_id,)
        ).fetchone()["revision"]


def _scope_body(revision):
    return {
        "schemaVersion": 1,
        "routeId": ROUTE,
        "routeRevision": 2,
        "clientSessionRevision": revision,
    }


def _provision(app, admin):
    core = app.state.core
    principal = core.auth.authenticate(admin["accessToken"])
    policy = _policy(core.context)
    core.room_presence.register_local(
        principal,
        policy,
        device_name="Owner tablet",
        room_names={ROOM: "Living room"},
        provider_reachable=True,
    )
    core.room_presence.fuse_local(
        principal, POLICY, [_signal(core.context, 1, 1_000_000)], now_ms=1_005_000
    )
    core.room_presence.fuse_local(
        principal, POLICY, [_signal(core.context, 2, 1_006_000)], now_ms=1_006_500
    )
    return policy


def test_durable_encrypted_local_fusion_and_authenticated_public_projection(server):
    app, client, settings, _clock = server
    admin = ready(server)
    _provision(app, admin)
    context = app.state.core.context
    root = f"/api/v1/room-presence/{context.coreId}/{context.homeId}"

    scope = client.post(root + "/scope", headers=auth(admin), json=_scope_body(3))
    assert scope.status_code == 200, scope.text
    authority = scope.json()
    listed = client.post(
        root + "/devices/query",
        headers=auth(admin),
        json={"schemaVersion": 1, "authority": authority},
    )
    assert listed.status_code == 200, listed.text
    value = listed.json()["devices"][0]
    assert value["state"] == "present"
    assert value["confidencePermille"] == 880
    assert value["observedAtMs"] == 1_006_000
    assert value["advisoryOnly"] is True and value["grantsAccess"] is False
    assert "private-aa-bb-cc" not in listed.text
    with app.state.core.db.connection() as connection:
        row = connection.execute(
            "SELECT nonce,ciphertext FROM room_presence_state WHERE singleton=1"
        ).fetchone()
    assert len(row["nonce"]) == 12
    assert b"Owner tablet" not in row["ciphertext"]
    assert b"private-aa-bb-cc" not in row["ciphertext"]

    with TestClient(create_app(settings)) as restarted:
        durable_scope = restarted.post(
            root + "/scope", headers=auth(admin), json=_scope_body(3)
        ).json()
        durable = restarted.post(
            root + "/devices/query",
            headers=auth(admin),
            json={"schemaVersion": 1, "authority": durable_scope},
        )
        assert durable.status_code == 200, durable.text
        assert durable.json()["devices"] == listed.json()["devices"]


def test_calibration_requires_exact_preview_confirm_and_durable_readback(server):
    app, client, settings, _clock = server
    admin = ready(server)
    _provision(app, admin)
    context = app.state.core.context
    root = f"/api/v1/room-presence/{context.coreId}/{context.homeId}"
    authority = client.post(
        root + "/scope", headers=auth(admin), json=_scope_body(4)
    ).json()
    expected = {
        "schemaVersion": 1,
        "authority": authority,
        "deviceId": DEVICE,
        "expectedDeviceRevision": 9,
        "expectedModelRevision": 4,
        "roomId": ROOM,
        "expectedRoomRevision": 13,
        "expectedPolicyRevision": 7,
        "expectedConsentRevision": 11,
        "expectedCalibrationRevision": 1,
    }
    preview = client.post(
        root + f"/devices/{DEVICE}/calibration/preview",
        headers=auth(admin),
        json=expected,
    )
    assert preview.status_code == 200, preview.text
    confirm = client.post(
        root + f"/calibrations/{preview.json()['requestId']}/confirm",
        headers=auth(admin),
        json=preview.json(),
    )
    assert confirm.status_code == 200, confirm.text
    assert confirm.json()["status"] == "applied"
    readback = client.post(
        root + f"/devices/{DEVICE}/readback",
        headers=auth(admin),
        json={"schemaVersion": 1, "authority": authority},
    )
    assert readback.status_code == 200
    assert readback.json()["calibrationRevision"] == 2

    with TestClient(create_app(settings)) as restarted:
        replay = restarted.post(
            root + f"/calibrations/{preview.json()['requestId']}/confirm",
            headers=auth(admin),
            json=preview.json(),
        )
        assert replay.status_code == 200
        assert replay.json() == confirm.json()
        tampered = restarted.post(
            root + f"/calibrations/{preview.json()['requestId']}/confirm",
            headers=auth(admin),
            json={**preview.json(), "deviceRevision": 10},
        )
        assert tampered.status_code == 409
        assert tampered.json()["error"]["code"] == "idempotency_conflict"


def test_foreign_scope_session_route_and_revisions_fail_closed(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    _provision(app, admin)
    context = app.state.core.context
    root = f"/api/v1/room-presence/{context.coreId}/{context.homeId}"
    authority = client.post(
        root + "/scope", headers=auth(admin), json=_scope_body(5)
    ).json()

    for changed in (
        {"coreId": "f" * 32},
        {"homeId": "f" * 32},
        {"accountRevision": authority["accountRevision"] + 1},
        {"sessionFamilyId": "f" * 32},
        {"routeRevision": authority["routeRevision"] + 1},
    ):
        stale = client.post(
            root + "/devices/query",
            headers=auth(admin),
            json={"schemaVersion": 1, "authority": authority | changed},
        )
        assert stale.status_code in (404, 409), stale.text
        assert stale.json()["error"]["code"] in ("not_found", "revision_conflict")

    raw_route = client.post(
        root + "/signals",
        headers=auth(admin),
        json={"rawIdentifier": "must-not-be-an-http-contract"},
    )
    assert raw_route.status_code == 404
