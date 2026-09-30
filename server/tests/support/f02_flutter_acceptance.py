"""Run the production F02/F03 Flutter client through normal Core and HA WS."""

from pathlib import Path
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import auth, ready, server as core_fixture
from support.f02_ha_trace_fixture import ENTITY, HomeAssistantTraceFixture


def _provision(app, client, fixture):
    actor = ready((app, client, app.state.core.settings, app.state.core.settings.clock))
    scope = app.state.core.context
    resource_response = client.post(
        f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}",
        headers=auth(actor),
        json={"kind": "resource", "label": "Welcome automation", "order": 0},
    )
    if resource_response.status_code != 201:
        raise RuntimeError("resource_fixture_setup_failed")
    resource = resource_response.json()["record"]
    service_response = client.post(
        "/api/v1/admin/services", headers=auth(actor), json={
            "kind": "home_assistant", "name": "Trace HA",
            "baseUrl": fixture.url,
            "credentials": {"token": "trace-loopback-only"},
        },
    )
    if service_response.status_code != 201:
        raise RuntimeError("service_fixture_setup_failed")
    service = service_response.json()["service"]
    principal = app.state.core.auth.authenticate(actor["accessToken"])
    app.state.core.services.record_verification(
        principal, service["id"], service["revision"],
        state="authenticated", version="2026.9",
    )
    base = (
        f"/api/v1/admin/home-assistant/{scope.coreId}/{scope.homeId}"
        f"/resources/{resource['ref']['id']}"
    )
    preview = client.post(base + "/binding-preview", headers=auth(actor), json={
        "serviceId": service["id"], "expectedServiceRevision": 1,
        "expectedRevision": 1, "expectedAclRevision": 1,
        "entityId": ENTITY, "expectedBindingId": None,
    })
    if preview.status_code != 201:
        raise RuntimeError(
            f"binding_preview_fixture_setup_failed:{preview.status_code}:{preview.text}"
        )
    binding = client.post(
        base + "/binding-confirm", headers=auth(actor),
        json={"previewId": preview.json()["preview"]["id"]},
    )
    if binding.status_code != 201:
        raise RuntimeError(
            f"binding_confirm_fixture_setup_failed:{binding.status_code}:{binding.text}"
        )
    binding = binding.json()["binding"]
    trial_response = client.post(
        f"/api/v1/automation-trials/{scope.coreId}/{scope.homeId}",
        headers=auth(actor), json={
            "schemaVersion": 1, "requestKey": "flutter-ha-trace-trial-0001",
            "timezone": "UTC", "localStartDate": "2026-09-05",
            "rules": [{
                "ruleId": binding["id"], "eventKey": "automation_triggered",
                "deviceId": resource["ref"]["id"], "action": "turn_on",
                "priority": 50, "weekdays": [0, 1, 2, 3, 4, 5, 6],
                "startMinute": 0, "endMinute": 1440,
            }],
        },
    )
    if trial_response.status_code != 201:
        raise RuntimeError("trial_fixture_setup_failed")
    return actor, scope


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f02-client-") as root:
        generator = core_fixture.__wrapped__(Path(root))
        server = next(generator)
        app, client, _settings, _clock = server
        fixture = HomeAssistantTraceFixture()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        running = uvicorn.Server(
            uvicorn.Config(app, log_level="critical", access_log=False)
        )
        thread = threading.Thread(
            target=lambda: running.run(sockets=[listener]), daemon=True
        )
        try:
            actor, scope = _provision(app, client, fixture)
            thread.start()
            deadline = time.monotonic() + 5
            while not running.started:
                if not thread.is_alive() or time.monotonic() >= deadline:
                    raise RuntimeError("isolated_core_startup_failed")
                time.sleep(0.02)
            result = subprocess.run(
                [
                    "flutter", "test",
                    "test/features/server/server_automation_ha_normal_core_test.dart",
                ],
                env={
                    **os.environ,
                    "LARENOR_AUTOMATION_CORE_URL":
                        f"http://127.0.0.1:{listener.getsockname()[1]}",
                    "LARENOR_AUTOMATION_TOKEN": actor["accessToken"],
                    "LARENOR_AUTOMATION_CORE_ID": scope.coreId,
                    "LARENOR_AUTOMATION_HOME_ID": scope.homeId,
                },
                cwd=Path(__file__).resolve().parents[3], check=False,
            )
            if fixture.trace_list_calls != 1 or fixture.trace_get_calls != 1:
                raise RuntimeError("actual_trace_contract_failed")
            return result.returncode
        finally:
            running.should_exit = True
            if thread.is_alive():
                thread.join(timeout=5)
            listener.close()
            fixture.close()
            generator.close()


if __name__ == "__main__":
    sys.exit(main())
