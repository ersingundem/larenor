"""Real EV Client -> normal Core -> owned evcc TCP, including restart."""

from copy import deepcopy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import threading

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import auth, ready, server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp
from test_f46_evcc_production_loopback import _state


def main():
    state = _state()
    calls = []

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def do_GET(self):
            if (self.path != "/api/state" or
                    self.headers.get("Authorization") != "Bearer evcc_loopback-key"):
                self.send_error(404)
                return
            calls.append(("GET", self.path))
            raw = json.dumps(deepcopy(state), separators=(",", ":")).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)

        def do_POST(self):
            if (self.path != "/api/loadpoints/1/maxcurrent/8" or
                    self.headers.get("Authorization") != "Bearer evcc_loopback-key"):
                self.send_error(404)
                return
            calls.append(("POST", self.path))
            state["loadpoints"][0]["maxCurrent"] = 8
            state["loadpoints"][0]["chargePower"] = 1840
            # Deliberately lose the ACK after the real owned upstream effect.
            self.close_connection = True

    upstream = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=upstream.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="larenor-f46-client-") as root:
            state_file = Path(root) / "client-state.json"
            for phase in ("confirm", "restart"):
                generator = core_fixture.__wrapped__(Path(root))
                fixture = next(generator)
                try:
                    if phase == "confirm":
                        app, client, _settings, clock = fixture
                        pair = ready(fixture)
                        response = client.post("/api/v1/admin/services",
                            headers=auth(pair), json={
                                "name": "Owned evcc", "kind": "evcc",
                                "baseUrl": f"http://127.0.0.1:{upstream.server_port}",
                                "credentials": {"apiKey": "evcc_loopback-key"},
                            })
                        if response.status_code != 201:
                            raise RuntimeError("evcc_service_setup_failed")
                        service = response.json()["service"]
                        principal = app.state.core.auth.authenticate(pair["accessToken"])
                        app.state.core.services.record_verification(principal,
                            service["id"], service["revision"],
                            state="reachable", version="0.214.1")
                        context = app.state.core.context
                        base = f"/api/v1/ev-charging/{context.coreId}/{context.homeId}"
                        now = round(clock.now * 1000)
                        for endpoint, body in (
                            ("energy-windows", {
                                "schemaVersion": 1,
                                "expectedServiceRevision": service["revision"],
                                "expectedAcceptedRevision": 0,
                                "tariffRevision": 41, "solarRevision": 43,
                                "powerBudgetRevision": 47, "overrideRevision": 53,
                                "observedAtMs": now, "expiresAtMs": now + 3_600_000,
                                "slots": [{"startAtMs": now,
                                    "endAtMs": now + 3_600_000,
                                    "tariffMicrosPerKwh": -50_000,
                                    "solarSurplusW": 0, "homeBudgetW": 1840}],
                            }),
                            ("loadpoints/1/current-control", {
                                "schemaVersion": 1,
                                "expectedServiceRevision": service["revision"],
                                "expectedAuthorityRevision": 0, "enabled": True,
                            }),
                        ):
                            response = client.put(
                                f"{base}/providers/evcc/{service['id']}/{endpoint}",
                                headers=auth(pair), json=body)
                            if response.status_code != 200:
                                raise RuntimeError("evcc_authority_setup_failed")
                    with InstalledCoreTcp(fixture[0]) as tcp:
                        result = subprocess.run([
                            "flutter", "test", "--no-pub",
                            "test/features/ev_charging/ev_charging_normal_core_test.dart",
                        ], env={**os.environ,
                            "LARENOR_EV_CORE_URL": f"http://127.0.0.1:{tcp.port}",
                            "LARENOR_EV_PHASE": phase,
                            "LARENOR_EV_STATE_FILE": str(state_file),
                            "LARENOR_EV_DEPARTURE_MS": str(round(fixture[3].now * 1000) + 3_600_000)},
                            cwd=Path(__file__).resolve().parents[3],
                            timeout=120, check=False)
                        if result.returncode:
                            return result.returncode
                finally:
                    generator.close()
            if sum(method == "POST" for method, _path in calls) != 1:
                raise RuntimeError("evcc_duplicate_effect")
            position = next(i for i, call in enumerate(calls) if call[0] == "POST")
            if calls[position - 1] != ("GET", "/api/state"):
                raise RuntimeError("evcc_missing_fresh_preflight")
            if state["loadpoints"][0]["maxCurrent"] != 8:
                raise RuntimeError("evcc_exact_effect_invalid")
    finally:
        upstream.shutdown()
        upstream.server_close()
        thread.join(timeout=5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
