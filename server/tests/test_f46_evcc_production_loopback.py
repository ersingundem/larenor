from copy import deepcopy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading

from conftest import auth, ready


def _state():
    return {
        "version": "0.214.1",
        "startupCompleted": True,
        "apiReady": True,
        "gridConfigured": True,
        "currency": "EUR",
        "grid": {"power": 4210},
        "tariffGrid": -0.05,
        "circuits": {"main": {"parent": "", "maxPower": 11000}},
        "vehicles": {"car": {"capacity": 64}},
        "loadpoints": [
            {
                "name": "garage",
                "title": "Garage",
                "chargePower": 3680,
                "priority": 20,
                "connected": True,
                "charging": True,
                "vehicleName": "car",
                "vehicleSoc": 41,
                "minCurrent": 6,
                "maxCurrent": 16,
                "phasesActive": 1,
                "chargeVoltages": [230],
            }
        ],
    }


def test_normal_core_evcc_lost_ack_reconciles_changed_setpoint_without_replay(server):
    app, client, _settings, clock = server
    pair = ready(server)
    state = _state()
    calls = []
    guard = {"get_count": 0, "drift_get": None}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def _reply(self, value):
            raw = json.dumps(value, separators=(",", ":")).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            guard["get_count"] += 1
            if guard["get_count"] == guard["drift_get"]:
                state["loadpoints"][0]["chargePower"] = 3000
            calls.append(("GET", self.path, self.headers.get("Authorization")))
            assert self.path == "/api/state"
            assert self.headers["Authorization"] == "Bearer evcc_loopback-key"
            self._reply(deepcopy(state))

        def do_POST(self):
            calls.append(("POST", self.path, self.headers.get("Authorization")))
            assert self.path == "/api/loadpoints/1/maxcurrent/8"
            assert self.headers["Authorization"] == "Bearer evcc_loopback-key"
            state["loadpoints"][0]["maxCurrent"] = 8
            state["loadpoints"][0]["chargePower"] = 1840
            self.close_connection = True

    upstream = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=upstream.serve_forever, daemon=True)
    thread.start()
    try:
        created = client.post(
            "/api/v1/admin/services",
            headers=auth(pair),
            json={
                "name": "Loopback evcc",
                "kind": "evcc",
                "baseUrl": f"http://127.0.0.1:{upstream.server_port}",
                "credentials": {"apiKey": "evcc_loopback-key"},
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
        root = f"/api/v1/ev-charging/{context.coreId}/{context.homeId}"
        accepted = client.put(
            f"{root}/providers/evcc/{service['id']}/energy-windows",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "expectedServiceRevision": service["revision"],
                "expectedAcceptedRevision": 0,
                "tariffRevision": 41,
                "solarRevision": 43,
                "powerBudgetRevision": 47,
                "overrideRevision": 53,
                "observedAtMs": round(clock.now * 1000),
                "expiresAtMs": round((clock.now + 3600) * 1000),
                "slots": [
                    {
                        "startAtMs": round(clock.now * 1000),
                        "endAtMs": round((clock.now + 3600) * 1000),
                        "tariffMicrosPerKwh": -50_000,
                        "solarSurplusW": 0,
                        "homeBudgetW": 1840,
                    }
                ],
            },
        )
        assert accepted.status_code == 200, accepted.text
        authorized = client.put(
            f"{root}/providers/evcc/{service['id']}/loadpoints/1/current-control",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "expectedServiceRevision": service["revision"],
                "expectedAuthorityRevision": 0,
                "enabled": True,
            },
        )
        assert authorized.status_code == 200, authorized.text
        capability = client.get(f"{root}/capability", headers=auth(pair)).json()
        charger = capability["chargers"][0]
        preview = client.post(
            f"{root}/chargers/{charger['chargerId']}/previews",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "previewId": "e" * 32,
                "expectedChargerRevision": charger["chargerRevision"],
                "expectedScheduleRevision": 1,
                "expectedTariffRevision": 41,
                "expectedPowerBudgetRevision": 47,
                "departureAtMs": round((clock.now + 3600) * 1000),
                "targetSoc": 42,
            },
        )
        assert preview.status_code == 201, preview.text
        plan = preview.json()["preview"]
        assert plan["slots"][0]["currentAmp"] == 8
        command = {
            "schemaVersion": 1,
            "previewId": "e" * 32,
            "commandId": "f" * 32,
            "expectedPlanHash": plan["planHash"],
            "expectedChargerRevision": charger["chargerRevision"],
            "expectedScheduleRevision": 1,
        }
        command_url = f"{root}/chargers/{charger['chargerId']}/commands"
        first = client.post(command_url, headers=auth(pair), json=command)
        assert first.status_code == 201, first.text
        assert first.json()["receipt"] | {
            "targetCurrentAmp": 8,
            "observedCurrentAmp": None,
            "observedAtMs": None,
        } == first.json()["receipt"]
        assert first.json()["receipt"]["status"] == "uncertain"
        post_position = next(
            index for index, call in enumerate(calls) if call[0] == "POST"
        )
        assert calls[post_position - 1][0:2] == ("GET", "/api/state")
        repeated = client.post(command_url, headers=auth(pair), json=command)
        assert repeated.status_code == 201, repeated.text
        assert repeated.json() == first.json()
        assert sum(method == "POST" for method, _path, _auth in calls) == 1
        result = client.get(
            f"{command_url}/{'f' * 32}", headers=auth(pair)
        )
        assert result.status_code == 200, result.text
        receipt = result.json()["receipt"]
        assert receipt["status"] == "verified"
        assert receipt["targetCurrentAmp"] == 8
        assert receipt["observedCurrentAmp"] == 8
        assert receipt["observedAtMs"] == round(clock.now * 1000)
        assert receipt["chargerRevision"] == charger["chargerRevision"]
        assert sum(method == "POST" for method, _path, _auth in calls) == 1

        state["loadpoints"][0]["maxCurrent"] = 16
        state["loadpoints"][0]["chargePower"] = 3680
        refreshed = client.get(f"{root}/capability", headers=auth(pair)).json()
        next_charger = refreshed["chargers"][0]
        next_preview = client.post(
            f"{root}/chargers/{next_charger['chargerId']}/previews",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "previewId": "1" * 32,
                "expectedChargerRevision": next_charger["chargerRevision"],
                "expectedScheduleRevision": 1,
                "expectedTariffRevision": 41,
                "expectedPowerBudgetRevision": 47,
                "departureAtMs": round((clock.now + 3600) * 1000),
                "targetSoc": 42,
            },
        )
        assert next_preview.status_code == 201, next_preview.text
        next_plan = next_preview.json()["preview"]
        guard["drift_get"] = guard["get_count"] + 4
        blocked = client.post(
            f"{root}/chargers/{next_charger['chargerId']}/commands",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "previewId": "1" * 32,
                "commandId": "2" * 32,
                "expectedPlanHash": next_plan["planHash"],
                "expectedChargerRevision": next_charger["chargerRevision"],
                "expectedScheduleRevision": 1,
            },
        )
        assert blocked.status_code == 201, blocked.text
        assert blocked.json()["receipt"]["status"] == "uncertain"
        assert sum(method == "POST" for method, _path, _auth in calls) == 1
    finally:
        upstream.shutdown()
        upstream.server_close()
        thread.join(timeout=2)
