"""Actual F48 Flutter Client -> normal Core -> loopback evcc acceptance."""

from copy import deepcopy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import auth, login, ready, server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp


PASSWORD = "Synthetic new password 2026"


class EvccFixture:
    def __init__(self):
        self.state = {
            "version": "0.214.1",
            "startupCompleted": True,
            "apiReady": True,
            "gridConfigured": True,
            "currency": "EUR",
            "grid": {"power": 15_300},
            "tariffGrid": 0.25,
            "circuits": {
                "main": {"parent": "", "maxPower": 16_000},
            },
            "hems": {
                "status": {
                    "dimmed": True,
                    "maxConsumptionPower": 8_400,
                },
            },
            "vehicles": {"car": {"capacity": 64}},
            "loadpoints": [
                {
                    "name": "garage",
                    "title": "Garage",
                    "chargePower": 11_040,
                    "priority": 20,
                    "connected": True,
                    "charging": True,
                    "vehicleName": "car",
                    "vehicleSoc": 40,
                    "minCurrent": 6,
                    "maxCurrent": 16,
                    "phasesActive": 3,
                    "chargeVoltages": [229, 230, 231],
                },
            ],
        }
        self.calls = []
        self.errors = []
        owner = self

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

            def _valid(self, expected_path):
                return (
                    self.path == expected_path
                    and self.headers.get("Authorization")
                    == "Bearer evcc_acceptance-key"
                )

            def do_GET(self):
                owner.calls.append(("GET", self.path))
                if not self._valid("/api/state"):
                    owner.errors.append(("GET", self.path))
                    self.send_error(400)
                    return
                self._reply(deepcopy(owner.state))

            def do_POST(self):
                owner.calls.append(("POST", self.path))
                if not self._valid("/api/loadpoints/1/maxcurrent/6"):
                    owner.errors.append(("POST", self.path))
                    self.send_error(400)
                    return
                owner.state["loadpoints"][0]["maxCurrent"] = 6
                owner.state["loadpoints"][0]["chargePower"] = 4_140
                self._reply(6)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(
            target=self.server.serve_forever,
            name="f48-evcc-fixture",
            daemon=True,
        )
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    @property
    def post_count(self):
        return sum(method == "POST" for method, _path in self.calls)

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def _existing_login(client):
    response = login(client, "admin", PASSWORD, "F48 provisioner")
    if response.status_code != 200:
        raise RuntimeError("f48_login_failed:" + response.text)
    return response.json()


def _flutter(tcp, phase):
    return subprocess.run(
        [
            "flutter",
            "test",
            "--no-pub",
            "test/features/power_budget/power_budget_normal_core_test.dart",
        ],
        env={
            **os.environ,
            "LARENOR_F48_CORE_URL": f"http://127.0.0.1:{tcp.port}",
            "LARENOR_F48_PHASE": phase,
        },
        cwd=Path(__file__).resolve().parents[3],
        check=False,
    )


def main():
    upstream = EvccFixture()
    try:
        with tempfile.TemporaryDirectory(prefix="larenor-f48-client-") as root:
            service_id = None
            exact_readback_seen = False
            for phase in ("critical", "control", "restart"):
                generator = core_fixture.__wrapped__(Path(root))
                fixture = next(generator)
                app, client, _settings, _clock = fixture
                try:
                    if phase == "critical":
                        pair = ready(fixture)
                        created = client.post(
                            "/api/v1/admin/services",
                            headers=auth(pair),
                            json={
                                "name": "F48 isolated evcc",
                                "kind": "evcc",
                                "baseUrl": upstream.url,
                                "credentials": {
                                    "apiKey": "evcc_acceptance-key",
                                },
                            },
                        )
                        if created.status_code != 201:
                            raise RuntimeError(
                                "f48_service_create_failed:" + created.text
                            )
                        service = created.json()["service"]
                        service_id = service["id"]
                        principal = app.state.core.auth.authenticate(
                            pair["accessToken"]
                        )
                        app.state.core.services.record_verification(
                            principal,
                            service_id,
                            service["revision"],
                            state="reachable",
                            version="0.214.1",
                        )
                    else:
                        pair = _existing_login(client)
                    if phase == "control":
                        context = app.state.core.context
                        path = (
                            f"/api/v1/ev-charging/{context.coreId}/"
                            f"{context.homeId}/providers/evcc/{service_id}/"
                            "loadpoints/1/current-control"
                        )
                        authorized = client.put(
                            path,
                            headers=auth(pair),
                            json={
                                "schemaVersion": 1,
                                "expectedServiceRevision": 1,
                                "expectedAuthorityRevision": 0,
                                "enabled": True,
                            },
                        )
                        if authorized.status_code != 200:
                            raise RuntimeError(
                                "f48_authority_setup_failed:" + authorized.text
                            )
                    before = upstream.post_count
                    with InstalledCoreTcp(app) as tcp:
                        result = _flutter(tcp, phase)
                    if result.returncode:
                        return result.returncode
                    expected = 1 if phase in {"control", "restart"} else 0
                    if upstream.post_count != expected:
                        raise RuntimeError(
                            f"f48_dispatch_count_{phase}:"
                            f"{before}->{upstream.post_count}"
                        )
                    if phase == "control":
                        loadpoint = upstream.state["loadpoints"][0]
                        exact_readback_seen = (
                            loadpoint["maxCurrent"] == 6
                            and loadpoint["chargePower"] == 4_140
                        )
                        # Restore a reducible observation without another
                        # command. The restart phase must therefore be blocked
                        # by the durable hold, not by already being at minimum.
                        loadpoint["maxCurrent"] = 16
                        loadpoint["chargePower"] = 11_040
                finally:
                    generator.close()
            if (
                upstream.errors
                or upstream.post_count != 1
                or not exact_readback_seen
            ):
                raise RuntimeError("f48_exact_readback_failed")
        return 0
    finally:
        upstream.close()


if __name__ == "__main__":
    sys.exit(main())
