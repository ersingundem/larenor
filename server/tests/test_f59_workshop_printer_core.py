import uuid

from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from test_admin import activate, create as create_user


SECRET = "synthetic-octoprint-key-not-for-production"


def root(app):
    scope = app.state.core.context
    return f"/api/v1/workshop/{scope.coreId}/{scope.homeId}"


def octoprint(client, admin, app):
    response = client.post("/api/v1/admin/services", headers=auth(admin), json={
        "name": "Workshop OctoPrint",
        "kind": "octoprint",
        "baseUrl": "https://octoprint.fixture.invalid",
        "credentials": {"apiKey": SECRET},
    })
    assert response.status_code == 201, response.text
    service = response.json()["service"]
    actor = app.state.core.auth.authenticate(admin["accessToken"])
    app.state.core.services.record_verification(
        actor, service["id"], service["revision"],
        state="authenticated", version="1.10.3",
    )
    return service


def state(clock, **safety):
    return {
        "job": {
            "jobId": uuid.uuid4().hex,
            "state": "printing",
            "progressPermille": 400,
            "remainingSeconds": 600,
        },
        "material": {
            "kind": "pla",
            "remainingGrams": 250.0,
        },
        "safety": {
            "connectivity": "online",
            "thermal": "normal",
            "filament": "available",
            "door": "closed",
            "emergency": "clear",
            "observedAt": clock.now,
            **safety,
        },
    }


def register(client, admin, app, clock, service, **safety):
    response = client.post(root(app) + "/printers", headers=auth(admin), json={
        "schemaVersion": 1,
        "registrationId": uuid.uuid4().hex,
        "name": "Workshop printer",
        "serviceId": service["id"],
        "expectedServiceRevision": service["revision"],
        **state(clock, **safety),
    })
    assert response.status_code == 201, response.text
    return response.json()["printer"]


def preview_body(printer, *, action="pause", request_key="pause-request-key-0001"):
    return {
        "schemaVersion": 1,
        "expectedPrinterRevision": printer["revision"],
        "expectedServiceRevision": printer["serviceRef"]["revision"],
        "expectedJobRevision": printer["job"]["revision"],
        "expectedMaterialRevision": printer["material"]["revision"],
        "expectedSafetyRevision": printer["safety"]["revision"],
        "requestKey": request_key,
        "action": action,
    }


def test_printer_job_material_and_safety_revisions_are_exact_and_secret_free(server):
    app, client, settings, clock = server
    admin = ready(server)
    service = octoprint(client, admin, app)
    printer = register(client, admin, app, clock, service)
    assert printer["revision"] == 1
    assert printer["serviceRef"] == {"id": service["id"], "revision": 1}
    assert [printer[name]["revision"] for name in ("job", "material", "safety")] == [1, 1, 1]
    assert SECRET not in str(printer)
    assert all(key not in str(printer).lower() for key in ("gcode", "path", "credential"))

    update = {
        "schemaVersion": 1,
        "expectedPrinterRevision": 1,
        "expectedServiceRevision": 1,
        "expectedJobRevision": 1,
        "expectedMaterialRevision": 1,
        "expectedSafetyRevision": 1,
        **state(clock),
    }
    updated = client.put(
        root(app) + f"/printers/{printer['ref']['id']}/state",
        headers=auth(admin), json=update,
    )
    assert updated.status_code == 200, updated.text
    changed = updated.json()["printer"]
    assert changed["revision"] == 2
    assert [changed[name]["revision"] for name in ("job", "material", "safety")] == [2, 2, 2]
    stale = client.put(
        root(app) + f"/printers/{printer['ref']['id']}/state",
        headers=auth(admin), json=update,
    )
    assert stale.status_code == 409
    assert stale.json()["error"]["code"] == "workshop_state_changed"

    with TestClient(create_app(settings)) as restarted:
        listed = restarted.get(root(app) + "/printers", headers=auth(admin))
        assert listed.status_code == 200
        assert listed.json()["printers"] == [changed]


def test_admin_preview_confirm_is_bounded_idempotent_and_never_dispatches(server):
    app, client, settings, clock = server
    owner = ready(server)
    service = octoprint(client, owner, app)
    printer = register(client, owner, app, clock, service)
    create_user(client, owner, "delegate", "admin")
    delegate = activate(client, "delegate")
    create_user(client, owner, "member", "member")
    member = activate(client, "member")
    endpoint = root(app) + f"/printers/{printer['ref']['id']}/previews"
    body = preview_body(printer)

    assert client.post(endpoint, headers=auth(member), json=body).status_code == 403
    for forbidden in (
        {**body, "action": "startPrint"},
        {**body, "gcode": "M112"},
        {**body, "path": "/private/job.gcode"},
        {**body, "credentials": {"apiKey": SECRET}},
    ):
        rejected = client.post(endpoint, headers=auth(delegate), json=forbidden)
        assert rejected.status_code == 400
        assert SECRET not in rejected.text

    preview = client.post(endpoint, headers=auth(delegate), json=body)
    assert preview.status_code == 201, preview.text
    pending = preview.json()["preview"]
    confirmed = client.post(
        endpoint + f"/{pending['id']}/confirm", headers=auth(delegate),
        json={"schemaVersion": 1, "confirmationToken": pending["confirmationToken"]},
    )
    retry = client.post(
        endpoint + f"/{pending['id']}/confirm", headers=auth(delegate),
        json={"schemaVersion": 1, "confirmationToken": pending["confirmationToken"]},
    )
    assert confirmed.status_code == 201 and retry.json() == confirmed.json()
    receipt = confirmed.json()["receipt"]
    assert receipt["state"] == "recorded"
    assert receipt["effect"] == "notDispatched"

    changed = client.post(endpoint, headers=auth(delegate), json={
        **body, "action": "cancel",
    })
    assert changed.status_code == 409
    assert changed.json()["error"]["code"] == "workshop_intent_conflict"
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM workshop_intents").fetchone()[0] == 1
    with TestClient(create_app(settings)) as restarted:
        history = restarted.get(
            root(app) + f"/printers/{printer['ref']['id']}/intents",
            headers=auth(owner),
        )
        assert history.status_code == 200
        assert history.json()["intents"] == [receipt]


def test_hazard_offline_or_stale_state_blocks_every_intent_fail_closed(server):
    app, client, _settings, clock = server
    admin = ready(server)
    service = octoprint(client, admin, app)
    hazards = (
        {"connectivity": "offline"},
        {"thermal": "runaway"},
        {"filament": "runout"},
        {"door": "open"},
        {"emergency": "triggered"},
        {"observedAt": clock.now - 31},
    )
    for index, hazard in enumerate(hazards):
        printer = register(client, admin, app, clock, service, **hazard)
        response = client.post(
            root(app) + f"/printers/{printer['ref']['id']}/previews",
            headers=auth(admin),
            json=preview_body(printer, request_key=f"blocked-request-key-{index:04d}"),
        )
        assert response.status_code == 409
        assert response.json()["error"]["code"] == "workshop_safety_blocked"
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM workshop_intents").fetchone()[0] == 0
