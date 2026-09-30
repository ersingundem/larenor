import json
from dataclasses import dataclass

import pytest

from larenor_server.auth import Principal
from larenor_server.services.service import ServiceConnection
from larenor_server.services.transport import ProbeResponse
from larenor_server.workshop.provider import (
    WorkshopHttpProvider,
    WorkshopProviderError,
)


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
    script = ScriptFactory(response(200, octoprint_job()))
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
        "thermal": "normal",
        "filament": "unknown",
        "door": "unknown",
        "emergency": "clear",
        "supportedActions": ["pause", "cancel"],
        "observedAt": 1_788_609_600.0,
    }
    assert len(observed["jobId"]) == 32
    assert 1 <= observed["providerRevision"] <= 2**63 - 1
    assert script.created == [("https://octoprint.fixture.invalid", 5.0, 65536)]
    assert script.calls == [(
        "GET", "/api/job",
        {"Accept": "application/json", "X-Api-Key": API_KEY},
        None, None,
    )]
    assert script.closed == 1


def test_octoprint_pause_is_explicit_and_requires_preflight_and_get_readback():
    script = ScriptFactory(
        response(200, octoprint_job()),
        response(200, octoprint_job(completion=41.0)),
        response(204),
        response(200, octoprint_job("Paused", 40.0)),
    )
    provider = WorkshopHttpProvider(Clock(), transport_factory=script)
    observed = provider.observe(actor(), binding("octoprint"), PRINTER_ID)

    result = provider.execute(actor(), binding("octoprint"), command(observed, "pause"))

    assert result["observation"]["jobState"] == "paused"
    assert result["commandId"] == "5" * 32
    post = script.calls[2]
    assert post[:2] == ("POST", "/api/job")
    assert json.loads(post[3]) == {"action": "pause", "command": "pause"}
    assert post[4] is None
    assert script.calls[1][0:2] == ("GET", "/api/job")
    assert script.calls[3][0:2] == ("GET", "/api/job")


def test_moonraker_cancel_uses_fixed_endpoint_and_job_id_metadata():
    script = ScriptFactory(
        response(200, moonraker_status()), response(200, moonraker_metadata()),
        response(200, moonraker_status()), response(200, moonraker_metadata()),
        response(200, {"result": "ok"}),
        response(200, moonraker_status("cancelled", 0.4)),
        response(200, moonraker_metadata()),
    )
    provider = WorkshopHttpProvider(Clock(), transport_factory=script)
    observed = provider.observe(actor(), binding("moonraker"), PRINTER_ID)

    result = provider.execute(actor(), binding("moonraker"), command(observed, "cancel"))

    assert result["observation"]["jobState"] == "completed"
    assert script.calls[0] == (
        "GET", "/printer/objects/query",
        {"Accept": "application/json", "X-Api-Key": API_KEY}, None,
        {"print_stats": "", "virtual_sdcard": "", "webhooks": ""},
    )
    assert script.calls[1][-1] == {"filename": "models/part.gcode"}
    assert script.calls[4][0:4] == (
        "POST", "/printer/print/cancel",
        {"Accept": "application/json", "X-Api-Key": API_KEY}, None,
    )


def test_changed_upstream_job_is_rejected_before_any_write():
    other = octoprint_job()
    other["job"]["file"]["path"] = "models/other.gcode"
    script = ScriptFactory(response(200, octoprint_job()), response(200, other))
    provider = WorkshopHttpProvider(Clock(), transport_factory=script)
    observed = provider.observe(actor(), binding("octoprint"), PRINTER_ID)

    with pytest.raises(WorkshopProviderError, match="provider_snapshot_changed"):
        provider.execute(actor(), binding("octoprint"), command(observed, "cancel"))

    assert [call[0] for call in script.calls] == ["GET", "GET"]


def test_provider_rejects_unbound_actor_service_and_non_json_success():
    script = ScriptFactory(response(200, octoprint_job()))
    provider = WorkshopHttpProvider(Clock(), transport_factory=script)
    observed = provider.observe(actor(), binding("octoprint"), PRINTER_ID)
    changed = command(observed, "cancel")
    changed["serviceRevision"] = 8
    with pytest.raises(WorkshopProviderError, match="provider_binding_changed"):
        provider.execute(actor(), binding("octoprint"), changed)
    assert len(script.calls) == 1

    invalid = ScriptFactory(ProbeResponse(200, (("Content-Type", "text/html"),), b"{}"))
    with pytest.raises(WorkshopProviderError, match="provider_protocol_changed"):
        WorkshopHttpProvider(Clock(), transport_factory=invalid).observe(
            actor(), binding("octoprint"), PRINTER_ID
        )


def test_provider_capability_is_the_exact_cached_observation_only():
    script = ScriptFactory(response(200, octoprint_job()))
    provider = WorkshopHttpProvider(Clock(), transport_factory=script)
    observed = provider.observe(actor(), binding("octoprint"), PRINTER_ID)

    capability = provider.capability(actor(), binding("octoprint"), PRINTER_ID)

    assert capability == {
        "schemaVersion": 1,
        "providerRevision": observed["providerRevision"],
        "supportedActions": ["pause", "cancel"],
        "observedAt": observed["observedAt"],
    }
    assert len(script.calls) == 1
