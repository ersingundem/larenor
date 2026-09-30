import json
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

from fastapi.testclient import TestClient
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.services.transport import ProbeResponse

from conftest import Clock, auth, ready


SOURCE = "1" * 32
ENTITY = "remote.living_room_broadlink"
REQUEST = "2" * 32


class RegistryClient:
    def __init__(self, service):
        self.service = service

    @contextmanager
    def session(self, *, timeout, before_io=None, after_io=None):
        assert timeout == 5.0
        assert callable(before_io) and callable(after_io)
        if before_io is not None:
            before_io()
        yield self
        if after_io is not None:
            after_io()

    def list_entity_registry(self):
        return ({
            "entity_id": ENTITY,
            "platform": "broadlink",
            "config_entry_id": "entry_1",
            "device_id": "device_1",
            "unique_id": "broadlink_remote_fixture",
            "disabled_by": None,
        },)

    def list_device_registry(self):
        return ({
            "id": "device_1",
            "config_entries": ["entry_1"],
            "manufacturer": "Broadlink",
            "model": "RM4 mini",
        },)


class HaTransport:
    calls = []

    def __init__(self, base_url, *, timeout, max_bytes):
        assert timeout == 5.0 and max_bytes == 65_536

    @classmethod
    def reset(cls):
        cls.calls = []

    def request(
        self, method, path, *, headers=None, body=None, before_send=None, **_kwargs
    ):
        if before_send is not None:
            before_send()
        headers = dict(headers or {})
        assert headers["Authorization"] == "Bearer ha_fixture_token"
        type(self).calls.append((method, path, headers, body))
        if method == "GET":
            assert path == "/api/states/" + ENTITY
            payload = {
                "entity_id": ENTITY,
                "state": "on",
                "last_updated": "2026-09-30T12:00:00+00:00",
                "attributes": {"friendly_name": "Living room remote", "supported_features": 3},
            }
        else:
            assert method == "POST" and path in {
                "/api/services/remote/send_command",
                "/api/services/remote/learn_command",
            }
            assert headers["Content-Type"] == "application/json"
            payload = []
        return ProbeResponse(
            200,
            (("Content-Type", "application/json"),),
            json.dumps(payload, separators=(",", ":")).encode(),
        )

    def close(self):
        pass


def _service(app, client, pair, *, base_url=None):
    response = client.post(
        "/api/v1/admin/services",
        headers=auth(pair),
        json={
            "name": "Home Assistant",
            "kind": "home_assistant",
            "baseUrl": base_url or "https://home-assistant.fixture.invalid",
            "credentials": {"token": "ha_fixture_token"},
        },
    )
    assert response.status_code == 201, response.text
    service = response.json()["service"]
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    app.state.core.services.record_verification(
        actor, service["id"], service["revision"],
        state="authenticated", version="2026.9.2",
    )
    return service


def _configure(server, *, base_url=None, fake_transport=True):
    app, client, _settings, _clock = server
    pair = ready(server)
    service = _service(app, client, pair, base_url=base_url)
    provider = app.state.core.legacy_remote_provider
    if fake_transport:
        provider._transport_factory = HaTransport
    provider._websocket_factory = RegistryClient
    context = app.state.core.context
    root = f"/api/v1/admin/legacy-remotes/{context.coreId}/{context.homeId}"
    accepted = client.put(
        root + "/sources/" + SOURCE,
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "expectedRevision": 0,
            "serviceId": service["id"],
            "expectedServiceRevision": service["revision"],
            "name": "Living room TV",
            "entityId": ENTITY,
            "learnedDeviceName": "television",
            "protocol": "ir",
            "commands": [{
                "key": "power_toggle",
                "commandName": "power",
                "maxRepeats": 1,
            }],
        },
    )
    assert accepted.status_code == 200, accepted.text
    return app, client, pair, root, service


def _preview(client, pair, root, catalog):
    item = catalog["items"][0]
    device, profile = item["device"], item["profile"]
    definition = profile["commands"][0]
    response = client.post(
        root + "/previews",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "authority": catalog["authority"],
            "requestId": REQUEST,
            "deviceId": device["deviceId"],
            "expectedDeviceRevision": device["revision"],
            "providerId": device["providerId"],
            "expectedProviderRevision": device["providerRevision"],
            "bridgeId": device["bridgeId"],
            "expectedBridgeRevision": device["bridgeRevision"],
            "profileId": profile["profileId"],
            "expectedProfileRevision": profile["revision"],
            "codeSetId": profile["codeSetId"],
            "expectedCodeSetRevision": profile["codeSetRevision"],
            "bindingId": definition["bindingId"],
            "commandKey": "power_toggle",
            "repeats": 1,
            "holdMs": 0,
        },
    )
    assert response.status_code == 201, response.text
    return response.json()["preview"]


def _learning_body(catalog):
    device = catalog["items"][0]["device"]
    profile = catalog["items"][0]["profile"]
    return {
        "schemaVersion": 1, "authority": catalog["authority"],
        "requestId": "e" * 32, "deviceId": device["deviceId"],
        "expectedDeviceRevision": device["revision"],
        "providerId": device["providerId"], "expectedProviderRevision": device["providerRevision"],
        "bridgeId": device["bridgeId"], "expectedBridgeRevision": device["bridgeRevision"],
        "profileId": profile["profileId"], "expectedProfileRevision": profile["revision"],
        "codeSetId": profile["codeSetId"], "expectedCodeSetRevision": profile["codeSetRevision"],
        "commandKey": "power_toggle",
    }


def test_actual_ha_learning_invalidates_prior_previews_and_never_fabricates_ack(server):
    HaTransport.reset()
    app, client, pair, root, _ = _configure(server)
    catalog = client.get(root, headers=auth(pair)).json()["catalog"]
    preview = _preview(client, pair, root, catalog)
    body = _learning_body(catalog)
    learned = client.post(root + "/learnings", headers=auth(pair), json=body)
    assert learned.status_code == 201, learned.text
    assert learned.json()["learning"] == {
        "schemaVersion": 1, "requestId": "e" * 32, "status": "uncertain",
        "reason": "lost_ack", "learningVerified": False, "receipt": None,
    }
    assert client.post(root + "/learnings", headers=auth(pair), json=body).status_code == 409
    recovered = client.get(root + "/learnings/" + "e" * 32, headers=auth(pair))
    assert recovered.json() == learned.json()
    stale_send = client.post(root + f"/previews/{REQUEST}/confirm", headers=auth(pair), json={
        "schemaVersion": 1, "authority": catalog["authority"], "preview": preview,
        "confirmationToken": preview["confirmationToken"],
    })
    assert stale_send.status_code == 409
    assert app.state.core.legacy_remote_provider._store.get(SOURCE)["revision"] == 2
    posts = [call for call in HaTransport.calls if call[0] == "POST"]
    assert len(posts) == 1 and posts[0][1] == "/api/services/remote/learn_command"
    assert json.loads(posts[0][3]) == {
        "entity_id": ENTITY, "device": "television", "command": "power",
        "command_type": "ir", "alternative": False,
    }


def test_ha_learning_capability_is_read_from_current_entity_before_effect(server):
    HaTransport.reset()
    app, client, pair, root, _ = _configure(server)
    catalog = client.get(root, headers=auth(pair)).json()["catalog"]
    before = app.state.core.legacy_remote_provider._state
    def without_learning(*args, **kwargs):
        state = before(*args, **kwargs)
        state["attributes"]["supported_features"] = 0
        return state
    app.state.core.legacy_remote_provider._state = without_learning
    result = client.post(root + "/learnings", headers=auth(pair), json=_learning_body(catalog))
    assert result.status_code == 201 and not result.json()["learning"]["learningVerified"]
    assert app.state.core.legacy_remote_provider._store.get(SOURCE)["revision"] == 1
    assert not any(call[0] == "POST" for call in HaTransport.calls)


def test_normal_broadlink_source_emits_once_but_truthfully_stays_uncertain(server):
    HaTransport.reset()
    _app, client, pair, root, _service_record = _configure(server)
    sources = client.get(root + "/sources", headers=auth(pair))
    assert sources.status_code == 200
    source = sources.json()["sources"][0]
    assert source["commandKeys"] == ["power_toggle"]
    assert len(source["configurationTag"]) == 64
    assert "television" not in sources.text
    assert "commandName" not in sources.text
    assert "ha_fixture_token" not in sources.text
    catalog = client.get(root, headers=auth(pair)).json()["catalog"]
    profile = catalog["items"][0]["profile"]
    assert 1 <= profile["revision"] <= (2**52)
    assert profile["codeSetRevision"] == profile["revision"]
    assert catalog["items"][0]["profile"]["commands"][0] == {
        "schemaVersion": 1,
        "bindingId": catalog["items"][0]["profile"]["commands"][0]["bindingId"],
        "key": "power_toggle",
        "maxRepeats": 1,
        "maxHoldMs": 0,
    }
    preview = _preview(client, pair, root, catalog)
    body = {
        "schemaVersion": 1,
        "authority": catalog["authority"],
        "preview": preview,
        "confirmationToken": preview["confirmationToken"],
    }
    result = client.post(
        root + f"/previews/{REQUEST}/confirm", headers=auth(pair), json=body
    )
    assert result.status_code == 200, result.text
    assert result.json()["result"] == {
        "schemaVersion": 1,
        "requestId": REQUEST,
        "status": "uncertain",
        "reason": "lost_ack",
        "deliveryVerified": False,
        "deviceStateVerified": False,
        "receipt": None,
    }
    repeated = client.post(
        root + f"/previews/{REQUEST}/confirm", headers=auth(pair), json=body
    )
    assert repeated.json() == result.json()
    posts = [call for call in HaTransport.calls if call[0] == "POST"]
    assert len(posts) == 1
    assert json.loads(posts[0][3]) == {
        "entity_id": ENTITY,
        "device": "television",
        "command": "power",
        "num_repeats": 1,
        "delay_secs": 0.4,
    }


def test_source_rejects_raw_codes_and_service_revision_drift(server):
    HaTransport.reset()
    app, client, pair, root, service = _configure(server)
    raw = client.put(
        root + "/sources/" + ("3" * 32),
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "expectedRevision": 0,
            "serviceId": service["id"],
            "expectedServiceRevision": service["revision"],
            "name": "Unsafe",
            "entityId": ENTITY,
            "learnedDeviceName": "television",
            "protocol": "ir",
            "commands": [{
                "key": "power_toggle", "commandName": "b64:AAAA",
                "maxRepeats": 1,
            }],
        },
    )
    assert raw.status_code == 400
    wrong_protocol = client.put(
        root + "/sources/" + ("4" * 32),
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "expectedRevision": 0,
            "serviceId": service["id"],
            "expectedServiceRevision": service["revision"],
            "name": "RF is outside this source contract",
            "entityId": ENTITY,
            "learnedDeviceName": "television",
            "protocol": "rf",
            "commands": [{
                "key": "power_toggle", "commandName": "power",
                "maxRepeats": 1,
            }],
        },
    )
    assert wrong_protocol.status_code == 400
    changed = client.patch(
        "/api/v1/admin/services/" + service["id"],
        headers=auth(pair),
        json={
            "name": "HA current",
            "baseUrl": service["baseUrl"],
            "expectedRevision": service["revision"],
            "credentials": {"token": "ha_fixture_token"},
        },
    )
    assert changed.status_code == 200, changed.text
    response = client.get(root, headers=auth(pair))
    assert response.status_code in {409, 503}


def test_command_editor_preserves_private_names_and_rejects_stale_cas(server):
    HaTransport.reset()
    app, client, pair, root, _service_record = _configure(server)
    source = client.get(root + "/sources", headers=auth(pair)).json()["sources"][0]
    body = {"schemaVersion": 1, "expectedRevision": source["revision"],
            "expectedConfigurationTag": source["configurationTag"],
            "upsert": [{"key": "volume_up", "commandName": "louder", "maxRepeats": 1},
                       {"key": "mute", "commandName": "quiet", "maxRepeats": 1}], "remove": []}
    path = root + "/sources/" + SOURCE + "/commands"
    saved = client.patch(path, headers=auth(pair), json=body)
    assert saved.status_code == 200, saved.text
    assert saved.json()["revision"] == 2
    assert client.patch(path, headers=auth(pair), json=body).status_code == 409
    projected = client.get(root + "/sources", headers=auth(pair))
    assert set(projected.json()["sources"][0]["commandKeys"]) == {"power_toggle", "volume_up", "mute"}
    assert all(secret not in projected.text for secret in ["television", "louder", "quiet", "commandName"])
    stored = app.state.core.legacy_remote_provider._store.get(SOURCE)["request"]
    assert stored.learnedDeviceName == "television"
    assert {item.key: item.commandName for item in stored.commands} == {
        "power_toggle": "power", "volume_up": "louder", "mute": "quiet"}
    current = projected.json()["sources"][0]
    removed = client.patch(path, headers=auth(pair), json={"schemaVersion": 1,
        "expectedRevision": 2, "expectedConfigurationTag": current["configurationTag"],
        "upsert": [], "remove": ["volume_up", "mute"]})
    assert removed.status_code == 200, removed.text
    latest = client.get(root + "/sources", headers=auth(pair)).json()["sources"][0]
    empty = client.patch(path, headers=auth(pair), json={"schemaVersion": 1,
        "expectedRevision": 3, "expectedConfigurationTag": latest["configurationTag"],
        "upsert": [], "remove": ["power_toggle"]})
    assert empty.status_code == 400
    assert not any(call[0] == "POST" for call in HaTransport.calls)


def test_command_editor_rejects_raw_signal_and_closed_body_before_io(server):
    HaTransport.reset()
    _app, client, pair, root, _service_record = _configure(server)
    source = client.get(root + "/sources", headers=auth(pair)).json()["sources"][0]
    body = {"schemaVersion": 1, "expectedRevision": source["revision"],
        "expectedConfigurationTag": source["configurationTag"],
        "upsert": [{"key": "play", "commandName": "b64:AA==", "maxRepeats": 1}], "remove": []}
    count = len(HaTransport.calls)
    path = root + "/sources/" + SOURCE + "/commands"
    assert client.patch(path, headers=auth(pair), json=body).status_code == 400
    body["upsert"][0]["commandName"] = "play"
    body["url"] = "http://invalid.test/"
    assert client.patch(path, headers=auth(pair), json=body).status_code == 400
    assert len(HaTransport.calls) == count


def test_service_authentication_retirement_closes_catalog_without_revision_change(
    server,
):
    HaTransport.reset()
    app, client, pair, root, service = _configure(server)
    actor = app.state.core.auth.authenticate(pair["accessToken"])

    class RetiringTransport(HaTransport):
        retired = False

        def request(self, method, path, **kwargs):
            response = super().request(method, path, **kwargs)
            if method == "GET" and not type(self).retired:
                type(self).retired = True
                app.state.core.services.record_verification(
                    actor,
                    service["id"],
                    service["revision"],
                    state="unavailable",
                )
            return response

    app.state.core.legacy_remote_provider._transport_factory = RetiringTransport

    response = client.get(root, headers=auth(pair))
    assert response.status_code in {409, 503}
    assert [call for call in HaTransport.calls if call[0] == "POST"] == []


def test_numeric_loopback_reaches_exact_ha_route_and_never_fakes_ack(server):
    requests = []

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
            requests.append((self.command, self.path, self.headers, None))
            self._reply({
                "entity_id": ENTITY,
                "state": "on",
                "last_updated": "2026-09-30T12:00:00+00:00",
                "attributes": {},
            })

        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            requests.append((self.command, self.path, self.headers, body))
            self._reply([])

    http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = Thread(target=http.serve_forever, daemon=True)
    thread.start()
    try:
        _app, client, pair, root, _record = _configure(
            server,
            base_url=f"http://127.0.0.1:{http.server_port}",
            fake_transport=False,
        )
        catalog = client.get(root, headers=auth(pair)).json()["catalog"]
        preview = _preview(client, pair, root, catalog)
        response = client.post(
            root + f"/previews/{REQUEST}/confirm",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "authority": catalog["authority"],
                "preview": preview,
                "confirmationToken": preview["confirmationToken"],
            },
        )
        assert response.status_code == 200, response.text
        assert response.json()["result"]["status"] == "uncertain"
        posts = [item for item in requests if item[0] == "POST"]
        assert len(posts) == 1
        assert posts[0][1] == "/api/services/remote/send_command"
        assert posts[0][2]["Authorization"] == "Bearer ha_fixture_token"
        assert json.loads(posts[0][3]) == {
            "entity_id": ENTITY,
            "device": "television",
            "command": "power",
            "num_repeats": 1,
            "delay_secs": 0.4,
        }
    finally:
        http.shutdown()
        http.server_close()
        thread.join(timeout=2)


def test_normal_provider_restart_reads_uncertain_without_second_post(
    tmp_path,
):
    HaTransport.reset()
    clock = Clock()
    settings = Settings(
        tmp_path / "data",
        tmp_path / "secrets/vault.key",
        clock=clock,
        login_ip_limit=100,
        login_account_limit=100,
        login_global_limit=100,
    )
    first_app = create_app(settings)
    first = TestClient(first_app)
    first.__enter__()
    pair = None
    root = None
    try:
        pair = ready((first_app, first, settings, clock))
        provider = first_app.state.core.legacy_remote_provider
        provider._transport_factory = HaTransport
        provider._websocket_factory = RegistryClient
        service = _service(first_app, first, pair)
        context = first_app.state.core.context
        root = f"/api/v1/admin/legacy-remotes/{context.coreId}/{context.homeId}"
        accepted = first.put(
            root + "/sources/" + SOURCE,
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "expectedRevision": 0,
                "serviceId": service["id"],
                "expectedServiceRevision": service["revision"],
                "name": "Living room TV",
                "entityId": ENTITY,
                "learnedDeviceName": "television",
                "protocol": "ir",
                "commands": [{
                    "key": "power_toggle",
                    "commandName": "power",
                    "maxRepeats": 1,
                }],
            },
        )
        assert accepted.status_code == 200, accepted.text
        catalog = first.get(root, headers=auth(pair)).json()["catalog"]
        preview = _preview(first, pair, root, catalog)
        result = first.post(
            root + f"/previews/{REQUEST}/confirm",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "authority": catalog["authority"],
                "preview": preview,
                "confirmationToken": preview["confirmationToken"],
            },
        ).json()
        assert result["result"]["status"] == "uncertain"
    finally:
        first.__exit__(None, None, None)
    second_app = create_app(settings)
    with TestClient(second_app) as second:
        provider = second_app.state.core.legacy_remote_provider
        provider._transport_factory = HaTransport
        provider._websocket_factory = RegistryClient
        recovered = second.get(
            root + f"/results/{REQUEST}", headers=auth(pair)
        )
        assert recovered.status_code == 200, recovered.text
        assert recovered.json() == result
    assert len([call for call in HaTransport.calls if call[0] == "POST"]) == 1
