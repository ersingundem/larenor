import uuid

import pytest

from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from test_admin import activate, create as create_user


SECRET = "synthetic-octoprint-key-not-for-production"


def root(app):
    scope = app.state.core.context
    return f"/api/v1/workshop/{scope.coreId}/{scope.homeId}"


def printer_service(client, admin, app, *, kind="octoprint"):
    response = client.post("/api/v1/admin/services", headers=auth(admin), json={
        "name": f"Workshop {kind}",
        "kind": kind,
        "baseUrl": f"https://{kind}.fixture.invalid",
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


def octoprint(client, admin, app):
    return printer_service(client, admin, app)


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
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE workshop_printers SET thermal='runaway' WHERE id=?",
            (printer["ref"]["id"],),
        )
    with pytest.raises(StartupError, match="workshop_storage_invalid"):
        create_app(settings)


def test_octoprint_and_moonraker_share_a_secret_free_provider_boundary(server):
    app, client, _settings, clock = server
    admin = ready(server)
    for kind in ("octoprint", "moonraker"):
        service = printer_service(client, admin, app, kind=kind)
        printer = register(client, admin, app, clock, service)
        assert printer["serviceRef"] == {
            "id": service["id"], "revision": service["revision"]
        }
        assert kind not in str(printer).lower()
        assert SECRET not in str(printer)


def test_exact_provider_refreshes_upstream_job_and_persists_command_readback(server):
    app, client, _settings, clock = server
    admin = ready(server)
    service = octoprint(client, admin, app)
    registered = register(client, admin, app, clock, service)
    upstream_job = "a" * 32

    class ExactProvider:
        exact_observations = True

        def __init__(self):
            self.state = "printing"
            self.calls = []

        def observe(self, actor, binding, printer_id):
            assert actor.id == admin["user"]["id"]
            assert binding.id == service["id"]
            assert binding.revision == service["revision"]
            assert printer_id == registered["ref"]["id"]
            return {
                "schemaVersion": 1,
                "providerRevision": 73 if self.state == "printing" else 74,
                "jobId": upstream_job,
                "jobState": self.state,
                "progressPermille": 410,
                "remainingSeconds": 590,
                "connectivity": "online",
                "thermal": "normal",
                "filament": "available",
                "door": "closed",
                "emergency": "clear",
                "supportedActions": (
                    ["pause", "cancel"] if self.state == "printing" else ["cancel"]
                ),
                "observedAt": clock.now,
            }

        def capability(self, *_args):
            pytest.fail("the exact observation is the capability snapshot")

        def execute(self, actor, binding, command):
            assert actor.id == command["actorId"]
            assert binding.id == command["serviceId"]
            assert command["expectedJobId"] == upstream_job
            assert command["expectedJobRevision"] == refreshed["job"]["revision"]
            assert command["providerRevision"] == 73
            self.calls.append(command)
            self.state = "paused"
            return {
                "schemaVersion": 1,
                "commandId": command["commandId"],
                "printerId": command["printerId"],
                "action": command["action"],
                "providerRevision": command["providerRevision"],
                "observation": self.observe(actor, binding, command["printerId"]),
            }

    provider = ExactProvider()
    app.state.core.workshop.provider = provider
    listed = client.get(root(app) + "/printers", headers=auth(admin))
    assert listed.status_code == 200, listed.text
    refreshed = listed.json()["printers"][0]
    assert refreshed["job"]["jobId"] == upstream_job
    assert refreshed["job"]["revision"] == registered["job"]["revision"] + 1
    assert refreshed["availableActions"] == ["pause", "cancel"]

    endpoint = root(app) + f"/printers/{refreshed['ref']['id']}/previews"
    pending = client.post(
        endpoint, headers=auth(admin), json=preview_body(refreshed)
    )
    assert pending.status_code == 201, pending.text
    preview = pending.json()["preview"]
    confirmed = client.post(
        endpoint + f"/{preview['id']}/confirm",
        headers=auth(admin),
        json={"schemaVersion": 1, "confirmationToken": preview["confirmationToken"]},
    )
    assert confirmed.status_code == 201, confirmed.text
    receipt = confirmed.json()["receipt"]
    assert receipt["effect"] == "applied"
    assert receipt["execution"]["readback"]["jobState"] == "paused"
    assert receipt["execution"]["readback"]["jobRevision"] == refreshed["job"]["revision"] + 1
    assert len(provider.calls) == 1

    current = client.get(root(app) + "/printers", headers=auth(admin)).json()["printers"][0]
    assert current["job"]["jobId"] == upstream_job
    assert current["job"]["state"] == "paused"


def test_admin_preview_confirm_is_bounded_idempotent_and_dispatches_once(server):
    app, client, settings, clock = server
    class Provider:
        calls = []

        def capability(self, actor, binding, printer_id):
            return {"schemaVersion": 1, "providerRevision": 3,
                    "supportedActions": ["pause", "cancel"],
                    "observedAt": clock.now}

        def execute(self, actor, binding, command):
            self.calls.append(command["commandId"])
            return {"schemaVersion": 1, "commandId": command["commandId"],
                    "printerId": command["printerId"], "action": command["action"],
                    "providerRevision": command["providerRevision"],
                    "jobRevision": command["expectedJobRevision"] + 1,
                    "jobState": "paused", "connectivity": "online",
                    "observedAt": clock.now}

    provider = Provider()
    app.state.core.workshop.provider = provider
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
    assert confirmed.status_code == 201
    receipt = confirmed.json()["receipt"]
    assert receipt["state"] == "recorded"
    assert receipt["effect"] == "applied"
    assert len(provider.calls) == 1

    changed = client.post(endpoint, headers=auth(delegate), json={
        **body, "action": "cancel",
    })
    assert changed.status_code == 409
    assert changed.json()["error"]["code"] == "workshop_intent_conflict"

    cancel_preview = client.post(endpoint, headers=auth(delegate), json={
        **body, "requestKey": "cancel-request-key-0002", "action": "cancel",
    }).json()["preview"]
    service_update = client.patch(
        "/api/v1/admin/services/" + service["id"], headers=auth(owner), json={
            "expectedRevision": 1,
            "name": "Renamed OctoPrint",
            "baseUrl": service["baseUrl"],
        },
    )
    assert service_update.status_code == 200
    stale_binding = client.post(
        endpoint + f"/{cancel_preview['id']}/confirm", headers=auth(delegate),
        json={
            "schemaVersion": 1,
            "confirmationToken": cancel_preview["confirmationToken"],
        },
    )
    assert stale_binding.status_code == 409
    assert stale_binding.json()["error"]["code"] == "workshop_binding_changed"

    clock.now += 31
    retry = client.post(
        endpoint + f"/{pending['id']}/confirm", headers=auth(delegate),
        json={"schemaVersion": 1, "confirmationToken": pending["confirmationToken"]},
    )
    assert retry.json() == confirmed.json()
    assert len(provider.calls) == 1
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM workshop_intents").fetchone()[0] == 1
    with TestClient(create_app(settings)) as restarted:
        history = restarted.get(
            root(app) + f"/printers/{printer['ref']['id']}/intents",
            headers=auth(owner),
        )
        assert history.status_code == 200
        assert history.json()["intents"] == [receipt]


def test_missing_provider_cannot_offer_actions_or_record_a_noop_confirmation(server):
    app, client, _settings, clock = server
    admin = ready(server)
    service = octoprint(client, admin, app)
    printer = register(client, admin, app, clock, service)
    assert printer["availableActions"] == []
    endpoint = root(app) + f"/printers/{printer['ref']['id']}/previews"
    rejected = client.post(endpoint, headers=auth(admin), json=preview_body(printer))
    assert rejected.status_code == 503
    assert rejected.json()["error"]["code"] == "workshop_provider_unavailable"
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM workshop_intents").fetchone()[0] == 0
        assert connection.execute("SELECT COUNT(*) FROM workshop_effects").fetchone()[0] == 0


def test_provider_removed_after_preview_cannot_create_a_noop_intent(server):
    app, client, _settings, clock = server
    admin = ready(server)
    service = octoprint(client, admin, app)
    printer = register(client, admin, app, clock, service)

    class Provider:
        def capability(self, *_args):
            return {"schemaVersion": 1, "providerRevision": 3,
                    "supportedActions": ["pause", "cancel"], "observedAt": clock.now}

        def execute(self, *_args):
            pytest.fail("a removed provider must never receive a command")

    app.state.core.workshop.provider = Provider()
    endpoint = root(app) + f"/printers/{printer['ref']['id']}/previews"
    pending = client.post(endpoint, headers=auth(admin), json=preview_body(printer)).json()["preview"]
    app.state.core.workshop.provider = None
    rejected = client.post(endpoint + f"/{pending['id']}/confirm", headers=auth(admin),
        json={"schemaVersion": 1, "confirmationToken": pending["confirmationToken"]})
    assert rejected.status_code == 503
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM workshop_intents").fetchone()[0] == 0


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
