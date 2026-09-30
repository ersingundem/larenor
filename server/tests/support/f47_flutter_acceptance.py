"""Actual F47 Flutter -> normal Core -> owned evcc and HA TCP acceptance."""

from copy import deepcopy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from threading import Thread

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import auth, login, ready, server as core_fixture
from support.f47_home_assistant_fixture import FroniusHomeAssistantFixture
from support.installed_core_tcp import InstalledCoreTcp
from test_f47_evcc_battery_binding import state


PASSWORD = "Synthetic new password 2026"


class EvccFixture:
    token = "evcc_f47-synthetic-key"

    def __init__(self):
        self.payload = state()
        self.calls = []
        self.errors = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def do_GET(self):
                try:
                    assert self.path == "/api/state"
                    assert self.headers["Authorization"] == "Bearer " + owner.token
                    owner.calls.append(("GET", self.path))
                    raw = json.dumps(
                        deepcopy(owner.payload), separators=(",", ":")
                    ).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(raw)))
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.wfile.write(raw)
                except Exception as error:  # pragma: no cover - runner surfaces it
                    owner.errors.append(type(error).__name__)
                    self.send_error(503)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = Thread(
            target=self.server.serve_forever,
            name="f47-evcc-fixture",
            daemon=True,
        )
        self.thread.start()

    @property
    def base_url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def _create_service(app, client, pair, *, name, kind, base_url, credentials):
    response = client.post(
        "/api/v1/admin/services",
        headers=auth(pair),
        json={
            "name": name,
            "kind": kind,
            "baseUrl": base_url,
            "credentials": credentials,
        },
    )
    if response.status_code != 201:
        raise RuntimeError("f47_service_setup_failed:" + response.text)
    service = response.json()["service"]
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    app.state.core.services.record_verification(
        actor,
        service["id"],
        service["revision"],
        state="reachable" if kind == "evcc" else "authenticated",
        version="0.214.1" if kind == "evcc" else "2026.9",
    )
    return service


def _provision(app, client, pair, clock, evcc, ha):
    evcc_service = _create_service(
        app,
        client,
        pair,
        name="F47 isolated evcc",
        kind="evcc",
        base_url=evcc.base_url,
        credentials={"apiKey": evcc.token},
    )
    _create_service(
        app,
        client,
        pair,
        name="F47 isolated Home Assistant",
        kind="home_assistant",
        base_url=ha.base_url,
        credentials={"token": ha.token},
    )
    context = app.state.core.context
    root = f"/api/v1/energy-priorities/{context.coreId}/{context.homeId}"
    metadata = client.get(
        f"{root}/providers/evcc/{evcc_service['id']}/battery-binding",
        headers=auth(pair),
    )
    if metadata.status_code != 200:
        raise RuntimeError("f47_battery_catalog_failed:" + metadata.text)
    accepted = client.put(
        f"{root}/providers/evcc/{evcc_service['id']}/battery-binding",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "expectedServiceRevision": evcc_service["revision"],
            "expectedBindingRevision": 0,
            "expectedBatteryCatalogRevision": metadata.json()[
                "currentBatteryCatalogRevision"
            ],
            "backupReservePercent": 40,
            "maxChargePowerW": 4_000,
            "maxDischargePowerW": 3_000,
        },
    )
    if accepted.status_code != 200:
        raise RuntimeError("f47_battery_binding_failed:" + accepted.text)
    now = round(clock.now * 1000)
    windows = client.put(
        f"/api/v1/ev-charging/{context.coreId}/{context.homeId}/providers/evcc/"
        f"{evcc_service['id']}/energy-windows",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "expectedServiceRevision": evcc_service["revision"],
            "expectedAcceptedRevision": 0,
            "tariffRevision": 2,
            "solarRevision": 3,
            "powerBudgetRevision": 4,
            "overrideRevision": 5,
            "observedAtMs": now,
            "expiresAtMs": now + 3_600_000,
            "slots": [{
                "startAtMs": now,
                "endAtMs": now + 3_600_000,
                "tariffMicrosPerKwh": 210_000,
                "exportTariffMicrosPerKwh": 70_000,
                "solarSurplusW": 0,
                "homeBudgetW": 4_000,
                "solarEnergyWh": 5_000,
                "loadEnergyWh": 1_000,
            }],
        },
    )
    if windows.status_code != 200:
        raise RuntimeError("f47_energy_windows_failed:" + windows.text)


def _flutter(tcp, phase):
    return subprocess.run(
        [
            "flutter",
            "test",
            "--no-pub",
            "test/features/energy_priorities/energy_priority_normal_core_test.dart",
        ],
        env={
            **os.environ,
            "LARENOR_F47_CORE_URL": f"http://127.0.0.1:{tcp.port}",
            "LARENOR_F47_PHASE": phase,
            "LARENOR_F47_ENTITY": FroniusHomeAssistantFixture.entity,
        },
        cwd=Path(__file__).resolve().parents[3],
        timeout=180,
        check=False,
    )


def main():
    evcc = EvccFixture()
    ha = FroniusHomeAssistantFixture()
    try:
        with tempfile.TemporaryDirectory(prefix="larenor-f47-client-") as root:
            for phase in ("setup", "restart"):
                generator = core_fixture.__wrapped__(Path(root))
                fixture = next(generator)
                app, client, _settings, clock = fixture
                try:
                    if phase == "setup":
                        pair = ready(fixture)
                        _provision(app, client, pair, clock, evcc, ha)
                    else:
                        response = login(
                            client, "admin", PASSWORD, "F47 restart provisioner"
                        )
                        if response.status_code != 200:
                            raise RuntimeError("f47_restart_login_failed")
                    before_posts = ha.post_count
                    with InstalledCoreTcp(app) as tcp:
                        result = _flutter(tcp, phase)
                    if result.returncode:
                        return result.returncode
                    expected = 1 if phase == "setup" else 0
                    if ha.post_count - before_posts != expected:
                        raise RuntimeError(
                            f"f47_unexpected_mutation_{phase}:"
                            f"{before_posts}->{ha.post_count}"
                        )
                finally:
                    generator.close()
            if (
                evcc.errors
                or ha.errors
                or not evcc.calls
                or ha.post_count != 1
                or ha.percent != 40
            ):
                raise RuntimeError("f47_provider_contract_failed")
        return 0
    finally:
        ha.close()
        evcc.close()


if __name__ == "__main__":
    sys.exit(main())
