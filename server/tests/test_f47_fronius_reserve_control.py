import json
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.services.transport import ProbeResponse, ProbeTransportError
from test_f47_evcc_battery_binding import Transport as EvccTransport, state


ENTITY = "number.gen24_battery_minimum_reserve"


class RegistryClient:
    def __init__(self, service):
        self.service = service

    @contextmanager
    def session(self, *, timeout):
        assert timeout == 5.0
        yield self

    def list_entity_registry(self):
        return ({
            "entity_id": ENTITY,
            "platform": "fronius",
            "config_entry_id": "entry_1",
            "device_id": "device_1",
            "unique_id": "gen24-fixture-modbus-battery_minimum_reserve",
            "disabled_by": None,
        },)

    def list_device_registry(self):
        return ({
            "id": "device_1",
            "config_entries": ["entry_1"],
            "manufacturer": "Fronius International GmbH",
            "model": "GEN24 Plus",
        },)


class HaTransport:
    percent = 20
    updated = "2026-09-05T12:00:00+00:00"
    lost_ack = False
    calls = []
    before_post = None

    def __init__(self, base_url, *, timeout, max_bytes):
        assert timeout == 5.0 and max_bytes == 65_536

    @classmethod
    def reset(cls):
        cls.percent = 20
        cls.updated = "2026-09-05T12:00:00+00:00"
        cls.lost_ack = False
        cls.calls = []
        cls.before_post = None

    def request(self, method, path, headers=None, body=None, **_kwargs):
        if method == 'POST' and type(self).before_post is not None:
            callback, type(self).before_post = type(self).before_post, None
            callback()
        if _kwargs.get('before_send') is not None:
            _kwargs['before_send']()
        headers = dict(headers or {})
        self.calls.append((method, path, headers, body))
        assert headers["Authorization"] == "Bearer ha_fixture_token"
        if method == "GET":
            assert path == "/api/states/" + ENTITY
            payload = {
                "entity_id": ENTITY,
                "state": str(self.percent),
                "last_updated": self.updated,
                "attributes": {
                    "min": 0,
                    "max": 100,
                    "step": 1,
                    "unit_of_measurement": "%",
                },
            }
        else:
            assert (method, path) == (
                "POST", "/api/services/number/set_value"
            )
            assert headers["Content-Type"] == "application/json"
            assert json.loads(body) == {"entity_id": ENTITY, "value": 40}
            type(self).percent = 40
            type(self).updated = "2026-09-05T12:00:01+00:00"
            if self.lost_ack:
                raise ProbeTransportError("request_failed")
            payload = []
        return ProbeResponse(
            200,
            (("Content-Type", "application/json"),),
            json.dumps(payload, separators=(",", ":")).encode(),
        )

    def close(self):
        pass


def _create_service(app, client, pair, kind, name, credentials, *, base_url=None):
    created = client.post(
        "/api/v1/admin/services",
        headers=auth(pair),
        json={
            "name": name,
            "kind": kind,
            "baseUrl": base_url or f"https://{kind.replace('_', '-')}.fixture.invalid",
            "credentials": credentials,
        },
    )
    assert created.status_code == 201, created.text
    service = created.json()["service"]
    principal = app.state.core.auth.authenticate(pair["accessToken"])
    app.state.core.services.record_verification(
        principal,
        service["id"],
        service["revision"],
        state="reachable" if kind == "evcc" else "authenticated",
        version="0.214.1" if kind == "evcc" else "2026.9.2",
    )
    return service


def _configure(tmp_path, monkeypatch, *, ha_transport=HaTransport, ha_base_url=None):
    EvccTransport.calls = []
    EvccTransport.payload = state()
    monkeypatch.setattr(
        "larenor_server.evcc.provider.ServiceTransport", EvccTransport
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
    client = TestClient(app)
    client.__enter__()
    pair = ready((app, client, settings, clock))
    evcc = _create_service(
        app, client, pair, "evcc", "Energy", {"apiKey": "evcc_fixture-key"}
    )
    ha = _create_service(
        app,
        client,
        pair,
        "home_assistant",
        "HA",
        {"token": "ha_fixture_token"},
        base_url=ha_base_url,
    )
    context = app.state.core.context
    root = f"/api/v1/energy-priorities/{context.coreId}/{context.homeId}"
    metadata = client.get(
        f"{root}/providers/evcc/{evcc['id']}/battery-binding",
        headers=auth(pair),
    ).json()
    accepted = client.put(
        f"{root}/providers/evcc/{evcc['id']}/battery-binding",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "expectedServiceRevision": evcc["revision"],
            "expectedBindingRevision": 0,
            "expectedBatteryCatalogRevision": metadata[
                "currentBatteryCatalogRevision"
            ],
            "backupReservePercent": 40,
            "maxChargePowerW": 4_000,
            "maxDischargePowerW": 3_000,
        },
    )
    assert accepted.status_code == 200, accepted.text
    windows = client.put(
        f"/api/v1/ev-charging/{context.coreId}/{context.homeId}/providers/evcc/"
        f"{evcc['id']}/energy-windows",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "expectedServiceRevision": evcc["revision"],
            "expectedAcceptedRevision": 0,
            "tariffRevision": 2,
            "solarRevision": 3,
            "powerBudgetRevision": 4,
            "overrideRevision": 5,
            "observedAtMs": round(clock.now * 1000),
            "expiresAtMs": round((clock.now + 3600) * 1000),
            "slots": [{
                "startAtMs": round(clock.now * 1000),
                "endAtMs": round((clock.now + 3600) * 1000),
                "tariffMicrosPerKwh": 210_000,
                "exportTariffMicrosPerKwh": 70_000,
                "solarSurplusW": 0,
                "homeBudgetW": 4_000,
                "solarEnergyWh": 5_000,
                "loadEnergyWh": 1_000,
            }],
        },
    )
    assert windows.status_code == 200, windows.text
    control = app.state.core.fronius_reserve_control
    if ha_transport is not None:
        control._transport_factory = ha_transport
    control._websocket_factory = RegistryClient
    snapshot = client.get(root, headers=auth(pair)).json()
    bound = client.put(
        f"{root}/providers/fronius/{ha['id']}/reserve-binding",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "expectedServiceRevision": ha["revision"],
            "expectedBindingRevision": 0,
            "batteryId": snapshot["inputs"]["battery"]["resourceId"],
            "batteryProviderRevision": snapshot["inputs"]["battery"][
                "providerRevision"
            ],
            "reserveEntityId": ENTITY,
        },
    )
    assert bound.status_code == 200, bound.text
    return app, client, pair, settings, clock, root, ha


def _preview(client, pair, root):
    snapshot = client.get(root, headers=auth(pair)).json()
    assert snapshot["authority"]["canControl"] is True
    assert snapshot["inverter"] == {
        "schemaVersion": 1,
        "inverterId": snapshot["inverter"]["inverterId"],
        "revision": snapshot["inverter"]["revision"],
        "canCharge": False,
        "canDischarge": False,
        "writable": True,
        "physicalAcceptance": "manual",
        "canSetReserve": True,
        "controlSemantics": "reserve_percent",
    }
    response = client.post(
        root + "/reserve-previews",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": "d" * 32,
            "inputDigest": snapshot["plan"]["inputDigest"],
            "inverterId": snapshot["inverter"]["inverterId"],
            "expectedInverterRevision": snapshot["inverter"]["revision"],
            "expectedAccountRevision": snapshot["authority"]["accountRevision"],
            "expectedHomeRevision": snapshot["authority"]["homeRevision"],
            "targetReservePercent": 40,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


def test_fronius_binding_and_exact_reserve_receipt_never_claim_power_control(
    tmp_path, monkeypatch
):
    HaTransport.reset()
    app, client, pair, _settings, _clock, root, _ha = _configure(
        tmp_path, monkeypatch
    )
    try:
        preview = _preview(client, pair, root)
        confirmed = client.post(
            root + "/reserve-previews/" + preview["requestId"] + "/confirm",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "confirmationToken": preview["confirmationToken"],
            },
        )
        assert confirmed.status_code == 200, confirmed.text
        assert confirmed.json() == {
            "schemaVersion": 1,
            "requestId": "d" * 32,
            "status": "confirmed",
            "targetReservePercent": 40,
            "observedReservePercent": 40,
            "bindingRevision": 1,
        }
        assert [call[:2] for call in HaTransport.calls].count(
            ("POST", "/api/services/number/set_value")
        ) == 1
        assert client.post(
            root + "/previews",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "requestId": "e" * 32,
                "planId": client.get(root, headers=auth(pair)).json()["plan"]["planId"],
                "inputDigest": client.get(root, headers=auth(pair)).json()["plan"]["inputDigest"],
                "slotIndex": 0,
                "inverterId": preview["inverterId"],
                "expectedInverterRevision": preview["inverterRevision"],
                "expectedAccountRevision": preview["accountRevision"],
                "expectedHomeRevision": 1,
            },
        ).status_code == 403
    finally:
        client.__exit__(None, None, None)


def test_registry_replacement_before_socket_send_never_writes_old_binding(tmp_path, monkeypatch):
    HaTransport.reset()
    app, client, pair, _settings, _clock, root, _ha = _configure(tmp_path, monkeypatch)
    try:
        preview = _preview(client, pair, root)
        original = RegistryClient.list_entity_registry
        def replace():
            def changed(self):
                return tuple({**row, 'unique_id': 'replacement-modbus-battery_minimum_reserve'}
                             for row in original(self))
            monkeypatch.setattr(RegistryClient, 'list_entity_registry', changed)
        HaTransport.before_post = replace
        result = client.post(root + '/reserve-previews/' + preview['requestId'] + '/confirm',
            headers=auth(pair), json={'schemaVersion': 1, 'confirmationToken': preview['confirmationToken']})
        assert result.status_code in {409, 503}, result.text
        assert not any(method == 'POST' for method, *_ in HaTransport.calls)
        current = client.get(root, headers=auth(pair)).json()
        assert current['inverter']['canSetReserve'] is False
        assert current['inverter']['writable'] is False
    finally:
        client.__exit__(None, None, None)


def test_lost_ack_reconciles_from_causal_state_without_second_post(
    tmp_path, monkeypatch
):
    HaTransport.reset()
    app, client, pair, settings, _clock, root, _ha = _configure(
        tmp_path, monkeypatch
    )
    restarted = None
    try:
        preview = _preview(client, pair, root)
        HaTransport.lost_ack = True
        failed = client.post(
            root + "/reserve-previews/" + preview["requestId"] + "/confirm",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "confirmationToken": preview["confirmationToken"],
            },
        )
        assert failed.status_code == 503
        HaTransport.lost_ack = False
        client.__exit__(None, None, None)
        client = None
        restarted_app = create_app(settings)
        restarted = TestClient(restarted_app)
        restarted.__enter__()
        restarted_app.state.core.fronius_reserve_control._transport_factory = (
            HaTransport
        )
        restarted_app.state.core.fronius_reserve_control._websocket_factory = (
            RegistryClient
        )
        recovered = restarted.get(
            root + "/reserve-commands/" + preview["requestId"],
            headers=auth(pair),
        )
        assert recovered.status_code == 200, recovered.text
        assert recovered.json()["status"] == "confirmed"
        assert [call[:2] for call in HaTransport.calls].count(
            ("POST", "/api/services/number/set_value")
        ) == 1
    finally:
        if client is not None:
            client.__exit__(None, None, None)
        if restarted is not None:
            restarted.__exit__(None, None, None)


def test_service_revision_drift_retires_reserve_write_capability(
    tmp_path, monkeypatch
):
    HaTransport.reset()
    app, client, pair, _settings, _clock, root, ha = _configure(
        tmp_path, monkeypatch
    )
    try:
        before = client.get(root, headers=auth(pair)).json()
        assert before["inverter"]["canSetReserve"] is True
        updated = client.patch(
            "/api/v1/admin/services/" + ha["id"],
            headers=auth(pair),
            json={
                "name": "HA current",
                "baseUrl": "https://home-assistant.fixture.invalid",
                "expectedRevision": ha["revision"],
                "credentials": {"token": "ha_fixture_token"},
            },
        )
        assert updated.status_code == 200, updated.text
        after = client.get(root, headers=auth(pair))
        assert after.status_code == 200, after.text
        assert after.json()["authority"]["canControl"] is False
        assert after.json()["inverter"]["canSetReserve"] is False
        assert after.json()["inverter"]["writable"] is False
    finally:
        client.__exit__(None, None, None)


def test_numeric_loopback_home_assistant_reserve_write_reaches_normal_core(
    tmp_path, monkeypatch
):
    requests = []
    actual = {"percent": 20, "updated": "2026-09-05T12:00:00+00:00"}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def _reply(self, value):
            body = json.dumps(value, separators=(",", ":")).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            requests.append((self.command, self.path, self.headers["Authorization"], None))
            self._reply({
                "entity_id": ENTITY,
                "state": str(actual["percent"]),
                "last_updated": actual["updated"],
                "attributes": {
                    "min": 0, "max": 100, "step": 1,
                    "unit_of_measurement": "%",
                },
            })

        def do_POST(self):
            length = int(self.headers["Content-Length"])
            body = self.rfile.read(length)
            requests.append((self.command, self.path, self.headers["Authorization"], body))
            actual.update(
                percent=json.loads(body)["value"],
                updated="2026-09-05T12:00:01+00:00",
            )
            self._reply([])

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    client = None
    try:
        app, client, pair, _settings, _clock, root, _ha = _configure(
            tmp_path,
            monkeypatch,
            ha_transport=None,
            ha_base_url=f"http://127.0.0.1:{server.server_port}",
        )
        preview = _preview(client, pair, root)
        response = client.post(
            root + "/reserve-previews/" + preview["requestId"] + "/confirm",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "confirmationToken": preview["confirmationToken"],
            },
        )
        assert response.status_code == 200, response.text
        posts = [item for item in requests if item[0] == "POST"]
        assert len(posts) == 1
        assert posts[0][:3] == (
            "POST", "/api/services/number/set_value", "Bearer ha_fixture_token"
        )
        assert json.loads(posts[0][3]) == {"entity_id": ENTITY, "value": 40}
    finally:
        if client is not None:
            client.__exit__(None, None, None)
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
