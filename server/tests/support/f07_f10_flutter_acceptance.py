"""Run F07/F10 Flutter clients through normal Core and real-shaped HA history."""

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
from support.f07_ha_history_fixture import ENTITY, HomeAssistantHistoryFixture


def _provision(app, client, fixture):
    actor = ready((app, client, app.state.core.settings, app.state.core.settings.clock))
    scope = app.state.core.context
    resource = client.post(
        f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}",
        headers=auth(actor),
        json={"kind": "resource", "label": "Hall motion", "order": 0},
    ).json()["record"]
    service = client.post("/api/v1/admin/services", headers=auth(actor), json={
        "kind": "home_assistant", "name": "History HA",
        "baseUrl": fixture.url, "credentials": {"token": "history-loopback-only"},
    }).json()["service"]
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
        raise RuntimeError("binding_preview_fixture_setup_failed")
    confirmed = client.post(
        base + "/binding-confirm", headers=auth(actor),
        json={"previewId": preview.json()["preview"]["id"]},
    )
    if confirmed.status_code != 201:
        raise RuntimeError("binding_confirm_fixture_setup_failed")
    return actor, scope


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f07-f10-client-") as root:
        generator = core_fixture.__wrapped__(Path(root))
        server = next(generator)
        app, client, _settings, _clock = server
        fixture = HomeAssistantHistoryFixture()
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
                    "test/features/server/server_ha_evidence_normal_core_test.dart",
                ],
                cwd=Path(__file__).resolve().parents[3], check=False,
                env={
                    **os.environ,
                    "LARENOR_HA_EVIDENCE_CORE_URL":
                        f"http://127.0.0.1:{listener.getsockname()[1]}",
                    "LARENOR_HA_EVIDENCE_TOKEN": actor["accessToken"],
                    "LARENOR_HA_EVIDENCE_CORE_ID": scope.coreId,
                    "LARENOR_HA_EVIDENCE_HOME_ID": scope.homeId,
                },
            )
            if fixture.registry_calls != 2 or fixture.history_calls != 2:
                raise RuntimeError("actual_history_contract_failed")
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
