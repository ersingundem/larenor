import json
from datetime import datetime, timedelta
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
    history_clock = None

    def __init__(self, base_url, *, timeout, max_bytes):
        self.base_url = base_url

    def request(self, method, path, headers=None, body=None, **kwargs):
        before_send = kwargs.get("before_send")
        if before_send is not None:
            before_send()
        self.calls.append((method, path, dict(headers or {}), body))
        payload = self.payload
        if path == "/api/history/energy":
            query = kwargs["query_parameters"]
            slot_end = (
                datetime.fromisoformat(query["from"].replace("Z", "+00:00"))
                + timedelta(hours=1)
            ).isoformat(timespec="seconds").replace("+00:00", "Z")
            assert (query["aggregate"], query["grouped"], query["format"]) == (
                "hour",
                "false",
                "json",
            )
            payload = [
                {
                    "title": query["group"].title(),
                    "group": query["group"],
                    "isTemp": False,
                    "data": [
                        {
                            "start": query["from"],
                            "end": slot_end,
                            "energy": 100,
                            "returnEnergy": 0,
                            **(
                                {"socTemp": 39}
                                if query["group"] == "battery"
                                else {}
                            ),
                        }
                    ],
                }
            ]
            if self.history_clock is not None:
                self.history_clock.now += 1
        return ProbeResponse(
            200,
            (("Content-Type", "application/json"),),
            json.dumps(payload, separators=(",", ":")).encode(),
        )

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


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
    Transport.history_clock = None
    monkeypatch.setattr("larenor_server.evcc.provider.ServiceTransport", Transport)
    monkeypatch.setattr(
        "larenor_server.energy_priorities.history.ServiceTransport", Transport
    )
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
        context = app.state.core.context
        resource = client.post(
            f"/api/v1/admin/home-resources/{context.coreId}/{context.homeId}",
            headers=auth(pair),
            json={"kind": "resource", "label": "Battery", "order": 0},
        )
        assert resource.status_code == 201, resource.text
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
        with app.state.core.db.connection() as connection:
            connection.execute("BEGIN")
            actual_home_revision = app.state.core.home_resources._state(connection)[
                "revision"
            ]
        assert actual_home_revision > 1
        assert body["authority"]["homeRevision"] == actual_home_revision
        assert body["inputs"]["homeRevision"] == actual_home_revision
        assert body["inputs"]["battery"]["capacityWh"] == 10_000
        assert body["inputs"]["battery"]["stateOfChargeWh"] == 5_500
        assert body["inputs"]["reserve"]["backupReservePercent"] == 40
        assert body["inverter"]["canCharge"] is True
        assert body["inverter"]["canDischarge"] is True
        assert body["inverter"]["writable"] is False
        assert body["authority"]["canControl"] is False
        assert all(call[:2] == ("GET", "/api/state") for call in Transport.calls)

        Transport.history_clock = clock
        before_history_clock = clock.now
        backtest = client.get(root + "/reserve-backtest", headers=auth(pair))
        Transport.history_clock = None
        assert backtest.status_code == 200, backtest.text
        assert clock.now == before_history_clock + 2
        history = backtest.json()
        assert history["observedStatus"] == "sample_below_reserve"
        assert history["sampleCoverage"] == "partial"
        assert history["forecastCoverage"] == "partial"
        assert history["sampleCount"] == 1
        assert history["belowReserveSampleCount"] == 1
        assert history["forecastRecordCount"] == 1
        assert history["historicalPreferenceCoverage"] == "unavailable"
        assert [
            call[1] for call in Transport.calls if call[1] == "/api/history/energy"
        ] == ["/api/history/energy", "/api/history/energy"]

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
