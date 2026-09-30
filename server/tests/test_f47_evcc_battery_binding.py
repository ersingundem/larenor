import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.evcc.provider import EvccConnection, EvccHttpReader
from larenor_server.services.transport import ProbeResponse


class Transport:
    calls = []
    payload = {}

    def __init__(self, base_url, *, timeout, max_bytes):
        self.base_url = base_url

    def request(self, method, path, headers=None, body=None, **kwargs):
        self.calls.append((method, path, dict(headers or {}), body))
        return ProbeResponse(
            200,
            (("Content-Type", "application/json"),),
            json.dumps(self.payload, separators=(",", ":")).encode(),
        )

    def close(self):
        pass


def state():
    return {
        "version": "0.214.1",
        "startupCompleted": True,
        "apiReady": True,
        "gridConfigured": True,
        "currency": "EUR",
        "grid": {"power": -750},
        "tariffGrid": 0.21,
        "prioritySoc": 20,
        "battery": {
            "power": -1800,
            "capacity": 10,
            "soc": 55,
            "devices": [
                {
                    "name": "home-battery",
                    "power": -1800,
                    "capacity": 10,
                    "soc": 55,
                    "controllable": True,
                }
            ],
        },
        "circuits": {
            "main": {"name": "main", "power": -750, "maxPower": 11_000}
        },
        "vehicles": {},
        "loadpoints": [
            {
                "name": "garage",
                "title": "Garage",
                "chargePower": 0,
                "priority": 10,
                "connected": False,
                "charging": False,
                "maxCurrent": 16,
                "minCurrent": 6,
                "phasesActive": 0,
                "chargeVoltages": [],
            }
        ],
    }


def test_real_bounded_http_reads_battery_catalog_without_mutation():
    requests = []
    payload = state()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            requests.append((self.command, self.path, self.headers.get("Authorization")))
            body = json.dumps(payload, separators=(",", ":")).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        observation = EvccHttpReader(lambda: 1_800_000_000).state(
            EvccConnection(
                "a" * 32,
                7,
                f"http://127.0.0.1:{httpd.server_port}",
                "evcc_fixture-key",
            )
        )
    finally:
        httpd.shutdown()
        httpd.server_close()
        thread.join(timeout=2)
    assert requests == [("GET", "/api/state", "Bearer evcc_fixture-key")]
    assert observation.battery.capacity_wh == 10_000
    assert observation.battery.devices[0].controllable is True


def test_normal_core_binds_live_battery_to_sealed_reserve_and_forecast(
    tmp_path, monkeypatch
):
    Transport.calls = []
    Transport.payload = state()
    monkeypatch.setattr("larenor_server.evcc.provider.ServiceTransport", Transport)
    clock = Clock()
    settings = Settings(
        tmp_path / "data",
        tmp_path / "secrets/vault.key",
        clock=clock,
        login_ip_limit=100,
        login_account_limit=100,
        login_global_limit=100,
    )
    app = create_app(settings)
    with TestClient(app) as client:
        pair = ready((app, client, settings, clock))
        created = client.post(
            "/api/v1/admin/services",
            headers=auth(pair),
            json={
                "name": "Home energy",
                "kind": "evcc",
                "baseUrl": "https://evcc.fixture.invalid",
                "credentials": {"apiKey": "evcc_fixture-key"},
            },
        )
        assert created.status_code == 201, created.text
        service = created.json()["service"]
        principal = app.state.core.auth.authenticate(pair["accessToken"])
        app.state.core.services.record_verification(
            principal,
            service["id"],
            service["revision"],
            state="reachable",
            version="0.214.1",
        )
        context = app.state.core.context
        root = f"/api/v1/energy-priorities/{context.coreId}/{context.homeId}"
        binding_url = f"{root}/providers/evcc/{service['id']}/battery-binding"
        metadata = client.get(binding_url, headers=auth(pair))
        assert metadata.status_code == 200, metadata.text
        catalog_revision = metadata.json()["currentBatteryCatalogRevision"]
        accepted = client.put(
            binding_url,
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "expectedServiceRevision": service["revision"],
                "expectedBindingRevision": 0,
                "expectedBatteryCatalogRevision": catalog_revision,
                "backupReservePercent": 40,
                "maxChargePowerW": 4_000,
                "maxDischargePowerW": 3_000,
            },
        )
        assert accepted.json() == {"schemaVersion": 1, "bindingRevision": 1}
        windows_url = (
            f"/api/v1/ev-charging/{context.coreId}/{context.homeId}/providers/evcc/"
            f"{service['id']}/energy-windows"
        )
        windows = client.put(
            windows_url,
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "expectedServiceRevision": service["revision"],
                "expectedAcceptedRevision": 0,
                "tariffRevision": 2,
                "solarRevision": 3,
                "powerBudgetRevision": 4,
                "overrideRevision": 5,
                "observedAtMs": round(clock.now * 1000),
                "expiresAtMs": round((clock.now + 3600) * 1000),
                "slots": [
                    {
                        "startAtMs": round(clock.now * 1000),
                        "endAtMs": round((clock.now + 3600) * 1000),
                        "tariffMicrosPerKwh": 210_000,
                        "exportTariffMicrosPerKwh": 70_000,
                        "solarSurplusW": 0,
                        "homeBudgetW": 4_000,
                        "solarEnergyWh": 5_000,
                        "loadEnergyWh": 1_000,
                    }
                ],
            },
        )
        assert windows.status_code == 200, windows.text
        snapshot = client.get(root, headers=auth(pair))
        assert snapshot.status_code == 200, snapshot.text
        body = snapshot.json()
        assert body["inputs"]["battery"]["capacityWh"] == 10_000
        assert body["inputs"]["battery"]["stateOfChargeWh"] == 5_500
        assert body["inputs"]["reserve"]["backupReservePercent"] == 40
        assert body["inverter"]["canCharge"] is True
        assert body["inverter"]["canDischarge"] is True
        assert body["inverter"]["writable"] is False
        assert body["authority"]["canControl"] is False
        assert all(call[:2] == ("GET", "/api/state") for call in Transport.calls)

        clock.now += 1
        stable = client.get(root, headers=auth(pair))
        assert stable.status_code == 200
        assert stable.json()["plan"]["planId"] == body["plan"]["planId"]

        clock.now += 59
        refreshed = client.get(root, headers=auth(pair))
        assert refreshed.status_code == 200
        assert refreshed.json()["plan"]["planId"] != body["plan"]["planId"]

        Transport.payload["battery"]["capacity"] = 11
        Transport.payload["battery"]["devices"][0]["capacity"] = 11
        drift = client.get(root, headers=auth(pair))
        assert (drift.status_code, drift.json()["error"]["code"]) == (
            503,
            "energy_provider_unavailable",
        )

        Transport.payload = state()
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE evcc_battery_bindings SET record_hash=? WHERE service_id=?",
                ("0" * 64, service["id"]),
            )
        tampered = client.put(
            binding_url,
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "expectedServiceRevision": service["revision"],
                "expectedBindingRevision": 1,
                "expectedBatteryCatalogRevision": catalog_revision,
                "backupReservePercent": 45,
                "maxChargePowerW": 4_000,
                "maxDischargePowerW": 3_000,
            },
        )
        assert (tampered.status_code, tampered.json()["error"]["code"]) == (
            503,
            "energy_provider_unavailable",
        )
