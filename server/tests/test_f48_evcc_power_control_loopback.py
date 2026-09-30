from copy import deepcopy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading

import pytest

from larenor_server.auth import Principal
from larenor_server.database import Database
from larenor_server.evcc.control import (
    EvccCurrentControl, migrate_evcc_current_control,
)
from larenor_server.evcc.provider import (
    EvccBinding, EvccConnection, EvccRuntimeProviders,
)
from larenor_server.power_budget.runtime import build_power_budget_gateway
from larenor_server.power_budget.schema import migrate_power_budget


NOW = 1_800_000_000.0
SERVICE_ID = "a" * 32


def _state():
    return {
        "version": "0.214.1", "startupCompleted": True, "apiReady": True,
        "gridConfigured": True, "currency": "EUR",
        "grid": {"power": 9000}, "tariffGrid": 0.25,
        "circuits": {"main": {"parent": "", "maxPower": 11000}},
        "hems": {"status": {"dimmed": True,
                            "maxConsumptionPower": 8400}},
        "vehicles": {"car": {"capacity": 64}},
        "loadpoints": [{
            "name": "garage", "title": "Garage", "chargePower": 3680,
            "priority": 20, "connected": True, "charging": True,
            "vehicleName": "car", "vehicleSoc": 40,
            "minCurrent": 6, "maxCurrent": 16, "phasesActive": 1,
            "chargeVoltages": [230],
        }],
    }


class _Services:
    @staticmethod
    def _assert_admin(_connection, actor):
        assert actor.role == "admin"

    @staticmethod
    def _evcc_connection_in(_connection, service_id, revision):
        assert (service_id, revision) == (SERVICE_ID, 7)


class _Windows:
    @staticmethod
    def is_single_current_window(_observation, _revision):
        return False


def _actor():
    return Principal("b" * 32, "admin", "admin", False,
                     "c" * 32, "d" * 32)


def test_real_loopback_manual_reduction_has_causal_readback_and_no_replay(
        tmp_path):
    state = _state()
    calls = []

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
            calls.append(("GET", self.path, self.headers.get("Authorization")))
            assert self.path == "/api/state"
            assert self.headers["Authorization"] == "Bearer evcc_loopback-key"
            self._reply(deepcopy(state))

        def do_POST(self):
            calls.append(("POST", self.path, self.headers.get("Authorization")))
            assert self.path == "/api/loadpoints/1/maxcurrent/13"
            assert self.headers["Authorization"] == "Bearer evcc_loopback-key"
            state["loadpoints"][0]["maxCurrent"] = 13
            state["loadpoints"][0]["chargePower"] = 2990
            self._reply(13)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    database = Database(tmp_path / "core.sqlite3")
    database.create_schema()
    with database.transaction() as connection:
        migrate_power_budget(connection)
        migrate_evcc_current_control(connection)
    binding = EvccBinding(
        "core", "home", 2, 3, lambda _actor: 5,
        EvccConnection(
            SERVICE_ID, 7, f"http://127.0.0.1:{server.server_port}",
            "evcc_loopback-key"),
        lambda: None,
    )
    control = EvccCurrentControl(
        database, audit_key=b"c" * 32, clock=lambda: NOW,
        services=_Services(), binding_resolver=lambda: binding,
        energy_windows=_Windows())
    control.authorize(
        _actor(), service_id=SERVICE_ID, service_revision=7,
        loadpoint_index=1, expected_authority_revision=0, enabled=True)
    provider = EvccRuntimeProviders(
        binding, clock=lambda: NOW, control_authority=control).power_budget
    gateway = build_power_budget_gateway(
        provider, database=database, master_key=b"p" * 32,
        clock=lambda: NOW)
    try:
        snapshot = gateway.snapshot(_actor())
        assert snapshot["commandEndpointAvailable"] is True
        assert [(item["loadId"], item["targetW"])
                for item in snapshot["plan"]["actions"]] == [
            ("evcc-lp-1", 3080)]
        receipt = gateway.confirm(
            _actor(), preview_id=snapshot["plan"]["id"],
            expected_plan_hash=snapshot["plan"]["planHash"],
            request_key="loopback-manual-control")
        assert receipt["status"] == "verified"
        assert state["loadpoints"][0]["maxCurrent"] == 13
        repeated = gateway.confirm(
            _actor(), preview_id=snapshot["plan"]["id"],
            expected_plan_hash=snapshot["plan"]["planHash"],
            request_key="loopback-manual-control")
        assert repeated == receipt
        assert sum(method == "POST" for method, _path, _auth in calls) == 1
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


@pytest.mark.parametrize("changed_revision", ["account", "home"])
def test_last_observation_authority_drift_blocks_evcc_write(
        tmp_path, changed_revision):
    state = _state()
    calls = []
    current = {"account": 5, "home": 3, "gets": 0}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def do_GET(self):
            current["gets"] += 1
            if current["gets"] == 3:
                current[changed_revision] += 1
            calls.append(("GET", self.path))
            raw = json.dumps(state, separators=(",", ":")).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)

        def do_POST(self):
            calls.append(("POST", self.path))
            raw = b"13"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    database = Database(tmp_path / "core.sqlite3")
    database.create_schema()
    with database.transaction() as connection:
        migrate_power_budget(connection)
        migrate_evcc_current_control(connection)

    def binding():
        return EvccBinding(
            "core", "home", 2, current["home"],
            lambda _actor: current["account"],
            EvccConnection(
                SERVICE_ID, 7, f"http://127.0.0.1:{server.server_port}",
                "evcc_loopback-key"),
            lambda: None,
        )

    control = EvccCurrentControl(
        database, audit_key=b"c" * 32, clock=lambda: NOW,
        services=_Services(), binding_resolver=binding,
        energy_windows=_Windows())
    control.authorize(
        _actor(), service_id=SERVICE_ID, service_revision=7,
        loadpoint_index=1, expected_authority_revision=0, enabled=True)
    provider = EvccRuntimeProviders(
        binding(), clock=lambda: NOW, control_authority=control).power_budget
    gateway = build_power_budget_gateway(
        provider, database=database, master_key=b"p" * 32,
        clock=lambda: NOW)
    try:
        snapshot = gateway.snapshot(_actor())
        receipt = gateway.confirm(
            _actor(), preview_id=snapshot["plan"]["id"],
            expected_plan_hash=snapshot["plan"]["planHash"],
            request_key=f"drift-{changed_revision}-control")
        assert receipt["status"] == "uncertain"
        assert not any(method == "POST" for method, _path in calls)
        assert gateway.confirm(
            _actor(), preview_id=snapshot["plan"]["id"],
            expected_plan_hash=snapshot["plan"]["planHash"],
            request_key=f"drift-{changed_revision}-control") == receipt
        assert not any(method == "POST" for method, _path in calls)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
