import json
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import socket
import threading

import pytest
from fastapi.testclient import TestClient

from larenor_server.auth import Principal
from larenor_server.app import create_app
from larenor_server.services.service import ServiceConnection
from larenor_server.services.transport import ProbeResponse
from larenor_server.workshop.provider import (
    WorkshopHttpProvider,
    WorkshopProviderError,
)
from conftest import auth, ready


ACTOR_ID = "1" * 32
PRINTER_ID = "2" * 32
SERVICE_ID = "3" * 32
API_KEY = "fixture-workshop-key"


@dataclass
class Clock:
    now: float = 1_788_609_600.0

    def __call__(self):
        return self.now


class ScriptTransport:
    def __init__(self, owner, base_url, timeout, max_bytes):
        self.owner = owner
        self.owner.created.append((base_url, timeout, max_bytes))

    def request(self, method, path, headers=None, body=None, *, query_parameters=None):
        self.owner.calls.append((method, path, headers, body, query_parameters))
        if not self.owner.script:
            pytest.fail("unexpected workshop request")
        result = self.owner.script.pop(0)
        if isinstance(result, Exception):
            raise result
        return result

    def close(self):
        self.owner.closed += 1


class ScriptFactory:
    def __init__(self, *script):
        self.script = list(script)
        self.calls = []
        self.created = []
        self.closed = 0

    def __call__(self, base_url, *, timeout, max_bytes):
        return ScriptTransport(self, base_url, timeout, max_bytes)


def response(status, value=None):
    body = b"" if value is None else json.dumps(value).encode("utf-8")
    headers = () if value is None else (("Content-Type", "application/json"),)
    return ProbeResponse(status, headers, body)


def actor():
    return Principal(ACTOR_ID, "admin", "admin", False, "4" * 32, "secret-session")


def binding(kind):
    return ServiceConnection(
        id=SERVICE_ID,
        revision=7,
        name="Workshop",
        kind=kind,
        base_url=f"https://{kind}.fixture.invalid",
        credentials={"apiKey": API_KEY},
    )


def octoprint_job(state="Printing", completion=40.0):
    return {
        "job": {"file": {
            "name": "part.gcode", "path": "models/part.gcode",
            "origin": "local", "size": 1200, "date": 1_700_000_000,
        }},
        "progress": {"completion": completion, "printTimeLeft": 600},
        "state": state,
    }


def octoprint_printer(
    state="Printing", *, actual=214.8, target=220.0, display_state=None
):
    flag = {
        "Printing": "printing",
        "Pausing": "pausing",
        "Paused": "paused",
        "Cancelling": "cancelling",
        "Operational": "operational",
        "Error": "error",
    }[state]
    flags = {
        "operational": False,
        "paused": False,
        "printing": False,
        "cancelling": False,
        "pausing": False,
        "error": False,
        "ready": False,
        "closedOrError": state == "Error",
    }
    flags[flag] = True
    return {
        "temperature": {
            "tool0": {"actual": actual, "target": target, "offset": 0},
            "bed": {"actual": 60.1, "target": None, "offset": 0},
        },
        "state": {"text": display_state or state, "flags": flags},
    }


def moonraker_status(state="printing", progress=0.4):
    return {"result": {
        "eventtime": 1234.5,
        "status": {
            "webhooks": {"state": "ready", "state_message": "Printer is ready"},
            "virtual_sdcard": {"is_active": state in {"printing", "paused"},
                               "progress": progress},
            "print_stats": {
                "filename": "models/part.gcode", "state": state,
                "total_duration": 100.0, "print_duration": 80.0,
                "filament_used": 20.0, "message": "", "info": {
                    "total_layer": 10, "current_layer": 4,
                },
            },
            "heaters": {"available_heaters": ["extruder", "heater_bed"]},
        },
    }}


def moonraker_temperatures():
    return {"result": {
        "eventtime": 1234.6,
        "status": {
            "extruder": {"temperature": 214.8, "target": 220.0},
            "heater_bed": {"temperature": 60.1, "target": 60.0},
        },
    }}


def moonraker_metadata():
    return {"result": {
        "filename": "models/part.gcode", "size": 1200,
        "modified": 1_700_000_000.0, "uuid": "file-uuid",
        "job_id": "0000BF", "print_start_time": 1_788_609_000.0,
        "estimated_time": 1000.0,
    }}


def command(observation, action):
    return {
        "schemaVersion": 1,
        "commandId": "5" * 32,
        "actorId": ACTOR_ID,
        "printerId": PRINTER_ID,
        "serviceId": SERVICE_ID,
        "serviceRevision": 7,
        "providerRevision": observation["providerRevision"],
        "expectedJobRevision": 11,
        "expectedJobId": observation["jobId"],
        "action": action,
    }


def test_octoprint_observation_is_bounded_authenticated_and_uses_real_file_identity():
    script = ScriptFactory(
        response(200, octoprint_job()),
        response(
            200,
            octoprint_printer(target=None, display_state="Printing from SD"),
        ),
    )
    provider = WorkshopHttpProvider(Clock(), transport_factory=script)

    observed = provider.observe(actor(), binding("octoprint"), PRINTER_ID)

    assert observed == {
        "schemaVersion": 1,
        "providerRevision": observed["providerRevision"],
        "jobId": observed["jobId"],
        "jobState": "printing",
        "progressPermille": 400,
        "remainingSeconds": 600,
        "connectivity": "online",
        "thermal": "unknown",
        "filament": "unknown",
        "door": "unknown",
        "emergency": "unknown",
        "temperatures": [
            {"name": "bed", "actualC": 60.1, "targetC": None},
            {"name": "tool0", "actualC": 214.8, "targetC": None},
        ],
        "supportedActions": ["pause", "cancel"],
        "observedAt": 1_788_609_600.0,
    }
    assert len(observed["jobId"]) == 32
    assert 1 <= observed["providerRevision"] <= 2**63 - 1
    assert script.created == [
        ("https://octoprint.fixture.invalid", 5.0, 65536),
        ("https://octoprint.fixture.invalid", 5.0, 65536),
    ]
    assert [(call[0], call[1], call[4]) for call in script.calls] == [
        ("GET", "/api/job", None),
        ("GET", "/api/printer", {"exclude": "sd"}),
    ]
    assert script.closed == 2


def test_octoprint_pause_is_explicit_and_requires_preflight_and_get_readback():
    script = ScriptFactory(
        response(200, octoprint_job()), response(200, octoprint_printer()),
        response(200, octoprint_job(completion=41.0)),
        response(200, octoprint_printer()),
        response(204),
        response(200, octoprint_job("Paused", 40.0)),
        response(200, octoprint_printer("Paused")),
    )
    provider = WorkshopHttpProvider(Clock(), transport_factory=script)
    observed = provider.observe(actor(), binding("octoprint"), PRINTER_ID)

    result = provider.execute(actor(), binding("octoprint"), command(observed, "pause"))

    assert result["observation"]["jobState"] == "paused"
    assert result["commandId"] == "5" * 32
    post = script.calls[4]
    assert post[:2] == ("POST", "/api/job")
    assert json.loads(post[3]) == {"action": "pause", "command": "pause"}
    assert post[4] is None
    assert script.calls[2][0:2] == ("GET", "/api/job")
    assert script.calls[5][0:2] == ("GET", "/api/job")


def test_moonraker_cancel_uses_fixed_endpoint_and_job_id_metadata():
    script = ScriptFactory(
        response(200, moonraker_status()), response(200, moonraker_temperatures()),
        response(200, moonraker_metadata()),
        response(200, moonraker_status()), response(200, moonraker_temperatures()),
        response(200, moonraker_metadata()),
        response(200, {"result": "ok"}),
        response(200, moonraker_status("cancelled", 0.4)),
        response(200, moonraker_temperatures()),
        response(200, moonraker_metadata()),
    )
    provider = WorkshopHttpProvider(Clock(), transport_factory=script)
    observed = provider.observe(actor(), binding("moonraker"), PRINTER_ID)

    result = provider.execute(actor(), binding("moonraker"), command(observed, "cancel"))

    assert result["observation"]["jobState"] == "completed"
    assert result["observation"]["temperatures"] == [
        {"name": "extruder", "actualC": 214.8, "targetC": 220.0},
        {"name": "heater_bed", "actualC": 60.1, "targetC": 60.0},
    ]
    assert script.calls[0] == (
        "GET", "/printer/objects/query",
        {"Accept": "application/json", "X-Api-Key": API_KEY}, None,
        {
            "print_stats": "", "virtual_sdcard": "", "webhooks": "",
            "heaters": "available_heaters",
        },
    )
    assert script.calls[1][-1] == {
        "extruder": "temperature,target",
        "heater_bed": "temperature,target",
    }
    assert script.calls[2][-1] == {"filename": "models/part.gcode"}
    assert script.calls[6][0:4] == (
        "POST", "/printer/print/cancel",
        {"Accept": "application/json", "X-Api-Key": API_KEY}, None,
    )


def test_changed_upstream_job_is_rejected_before_any_write():
    other = octoprint_job()
    other["job"]["file"]["path"] = "models/other.gcode"
    script = ScriptFactory(
        response(200, octoprint_job()), response(200, octoprint_printer()),
        response(200, other), response(200, octoprint_printer()),
    )
    provider = WorkshopHttpProvider(Clock(), transport_factory=script)
    observed = provider.observe(actor(), binding("octoprint"), PRINTER_ID)

    with pytest.raises(WorkshopProviderError, match="provider_snapshot_changed"):
        provider.execute(actor(), binding("octoprint"), command(observed, "cancel"))

    assert [call[0] for call in script.calls] == ["GET"] * 4


def test_provider_rejects_unbound_actor_service_and_non_json_success():
    script = ScriptFactory(
        response(200, octoprint_job()), response(200, octoprint_printer())
    )
    provider = WorkshopHttpProvider(Clock(), transport_factory=script)
    observed = provider.observe(actor(), binding("octoprint"), PRINTER_ID)
    changed = command(observed, "cancel")
    changed["serviceRevision"] = 8
    with pytest.raises(WorkshopProviderError, match="provider_binding_changed"):
        provider.execute(actor(), binding("octoprint"), changed)
    assert len(script.calls) == 2

    invalid = ScriptFactory(ProbeResponse(200, (("Content-Type", "text/html"),), b"{}"))
    with pytest.raises(WorkshopProviderError, match="provider_protocol_changed"):
        WorkshopHttpProvider(Clock(), transport_factory=invalid).observe(
            actor(), binding("octoprint"), PRINTER_ID
        )

    invalid_temperature = ScriptFactory(
        response(200, octoprint_job()),
        response(200, octoprint_printer(actual=None)),
    )
    with pytest.raises(WorkshopProviderError, match="provider_protocol_changed"):
        WorkshopHttpProvider(
            Clock(), transport_factory=invalid_temperature
        ).observe(actor(), binding("octoprint"), PRINTER_ID)


def test_provider_capability_is_the_exact_cached_observation_only():
    script = ScriptFactory(
        response(200, octoprint_job()), response(200, octoprint_printer())
    )
    provider = WorkshopHttpProvider(Clock(), transport_factory=script)
    observed = provider.observe(actor(), binding("octoprint"), PRINTER_ID)

    capability = provider.capability(actor(), binding("octoprint"), PRINTER_ID)

    assert capability == {
        "schemaVersion": 1,
        "providerRevision": observed["providerRevision"],
        "supportedActions": ["pause", "cancel"],
        "observedAt": observed["observedAt"],
    }
    assert len(script.calls) == 2


def test_normal_core_uses_loopback_octoprint_and_persists_exact_pause_readback(
    server,
):
    app, client, settings, clock = server
    upstream = {
        "state": "Printing",
        "completion": 10.0,
        "moveProgress": True,
        "actualC": 214.8,
        "posts": 0,
        "cancelPosts": 0,
        "gets": 0,
    }

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _reply(self, status, value=None):
            body = b"" if value is None else json.dumps(value).encode("utf-8")
            self.send_response(status)
            if value is not None:
                self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            assert self.headers.get("X-Api-Key") == API_KEY
            upstream["gets"] += 1
            if self.path == "/api/job":
                value = octoprint_job(
                    upstream["state"], upstream["completion"]
                )
                value["progress"]["printTimeLeft"] = round(
                    700 - upstream["completion"]
                )
                if upstream["moveProgress"]:
                    upstream["completion"] += 5
                self._reply(200, value)
                return
            if self.path == "/api/printer?exclude=sd":
                self._reply(
                    200,
                    octoprint_printer(
                        upstream["state"], actual=upstream["actualC"]
                    ),
                )
                return
            self._reply(404, {"error": "unknown"})

        def do_POST(self):
            assert self.headers.get("X-Api-Key") == API_KEY
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length))
            assert self.path == "/api/job"
            upstream["posts"] += 1
            if body == {"action": "pause", "command": "pause"}:
                upstream["state"] = "Paused"
                self._reply(204)
                return
            assert body == {"command": "cancel"}
            upstream["cancelPosts"] += 1
            upstream["state"] = "Operational"
            # The upstream mutation happened, but the connection was lost
            # before an HTTP acknowledgement reached the caller.
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()

        def log_message(self, *_args):
            pass

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        admin = ready(server)
        service_response = client.post(
            "/api/v1/admin/services",
            headers=auth(admin),
            json={
                "name": "Loopback OctoPrint",
                "kind": "octoprint",
                "baseUrl": f"http://127.0.0.1:{httpd.server_port}",
                "credentials": {"apiKey": API_KEY},
            },
        )
        assert service_response.status_code == 201, service_response.text
        service = service_response.json()["service"]
        principal = app.state.core.auth.authenticate(admin["accessToken"])
        app.state.core.services.record_verification(
            principal,
            service["id"],
            service["revision"],
            state="authenticated",
            version="1.10.3",
        )
        root = (
            f"/api/v1/workshop/{app.state.core.context.coreId}/"
            f"{app.state.core.context.homeId}"
        )
        catalog = client.get(root + "/catalog", headers=auth(admin))
        assert catalog.status_code == 200, catalog.text
        assert catalog.json() == {
            "schemaVersion": 1,
            "services": [{
                "id": service["id"],
                "revision": service["revision"],
                "name": "Loopback OctoPrint",
                "kind": "octoprint",
            }],
        }
        registration = {
            "schemaVersion": 1,
            "registrationId": PRINTER_ID,
            "name": "Loopback printer",
            "serviceId": service["id"],
            "expectedServiceRevision": service["revision"],
        }
        registered_response = client.post(
            root + "/printers/from-service",
            headers=auth(admin),
            json=registration,
        )
        assert registered_response.status_code == 201, registered_response.text
        registered = registered_response.json()["printer"]
        assert registered["material"] == {
            "revision": 1, "kind": "unknown", "remainingGrams": None,
        }
        first = client.get(root + "/printers", headers=auth(admin)).json()[
            "printers"
        ][0]
        second = client.get(root + "/printers", headers=auth(admin)).json()[
            "printers"
        ][0]
        assert second["job"]["jobId"] == first["job"]["jobId"]
        assert second["job"]["progressPermille"] > first["job"]["progressPermille"]
        assert second["job"]["remainingSeconds"] < first["job"]["remainingSeconds"]
        assert second["job"]["revision"] > first["job"]["revision"]
        assert second["temperature"] == first["temperature"]
        assert second["temperature"]["heaters"] == [
            {"name": "bed", "actualC": 60.1, "targetC": None},
            {"name": "tool0", "actualC": 214.8, "targetC": 220.0},
        ]
        upstream["moveProgress"] = False
        temperature_baseline = client.get(
            root + "/printers", headers=auth(admin)
        ).json()["printers"][0]
        upstream["actualC"] = 215.8
        authoritative = client.get(
            root + "/printers", headers=auth(admin)
        ).json()["printers"][0]
        assert authoritative["job"]["revision"] == temperature_baseline["job"][
            "revision"
        ]
        assert authoritative["temperature"]["revision"] > (
            temperature_baseline["temperature"]["revision"]
        )
        assert authoritative["temperature"]["heaters"][-1]["actualC"] == 215.8
        for key in ("thermal", "filament", "door", "emergency"):
            assert second["safety"][key] == "unknown"
        assert second["availableActions"] == ["pause", "cancel"]
        endpoint = root + f"/printers/{PRINTER_ID}/previews"
        pending = client.post(
            endpoint,
            headers=auth(admin),
            json={
                "schemaVersion": 1,
                "expectedPrinterRevision": authoritative["revision"],
                "expectedServiceRevision": authoritative["serviceRef"]["revision"],
                "expectedJobRevision": authoritative["job"]["revision"],
                "expectedMaterialRevision": authoritative["material"]["revision"],
                "expectedSafetyRevision": authoritative["safety"]["revision"],
                "requestKey": "loopback-pause-request-0001",
                "action": "pause",
            },
        )
        assert pending.status_code == 201, pending.text
        preview = pending.json()["preview"]
        receipt = client.post(
            endpoint + f"/{preview['id']}/confirm",
            headers=auth(admin),
            json={
                "schemaVersion": 1,
                "confirmationToken": preview["confirmationToken"],
            },
        )
        assert receipt.status_code == 201, receipt.text
        assert receipt.json()["receipt"]["effect"] == "applied"
        assert receipt.json()["receipt"]["execution"]["readback"][
            "jobState"
        ] == "paused"
        assert upstream["posts"] == 1
        repeated = client.post(
            endpoint + f"/{preview['id']}/confirm",
            headers=auth(admin),
            json={
                "schemaVersion": 1,
                "confirmationToken": preview["confirmationToken"],
            },
        )
        assert repeated.json() == receipt.json()
        assert upstream["posts"] == 1

        paused = client.get(root + "/printers", headers=auth(admin)).json()[
            "printers"
        ][0]
        assert paused["job"]["state"] == "paused"
        assert paused["availableActions"] == ["cancel"]
        cancel_pending = client.post(
            endpoint,
            headers=auth(admin),
            json={
                "schemaVersion": 1,
                "expectedPrinterRevision": paused["revision"],
                "expectedServiceRevision": paused["serviceRef"]["revision"],
                "expectedJobRevision": paused["job"]["revision"],
                "expectedMaterialRevision": paused["material"]["revision"],
                "expectedSafetyRevision": paused["safety"]["revision"],
                "requestKey": "loopback-cancel-request-0002",
                "action": "cancel",
            },
        ).json()["preview"]
        cancel_body = {
            "schemaVersion": 1,
            "confirmationToken": cancel_pending["confirmationToken"],
        }
        uncertain = client.post(
            endpoint + f"/{cancel_pending['id']}/confirm",
            headers=auth(admin),
            json=cancel_body,
        )
        assert uncertain.status_code == 201, uncertain.text
        assert uncertain.json()["receipt"]["effect"] == "unknown"
        assert uncertain.json()["receipt"]["execution"]["code"] == (
            "worker_ack_unknown"
        )
        assert upstream["posts"] == 2
        assert upstream["cancelPosts"] == 1
        uncertain_retry = client.post(
            endpoint + f"/{cancel_pending['id']}/confirm",
            headers=auth(admin),
            json=cancel_body,
        )
        assert uncertain_retry.json() == uncertain.json()
        assert upstream["posts"] == 2
        assert upstream["cancelPosts"] == 1
        get_count = upstream["gets"]
        with TestClient(create_app(settings)) as restarted:
            replay = restarted.post(
                root + "/printers/from-service",
                headers=auth(admin),
                json=registration,
            )
            assert replay.status_code == 201, replay.text
            assert replay.json()["printer"]["ref"]["id"] == PRINTER_ID
            assert upstream["gets"] == get_count
    finally:
        httpd.shutdown()
        httpd.server_close()
        thread.join(timeout=5)
