import json
from datetime import datetime, timezone

from conftest import auth, ready
from larenor_server.garden_irrigation.home_assistant import (
    HomeAssistantIrrigationProvider,
)
from larenor_server.garden_irrigation.runtime import build_irrigation_gateway
from larenor_server.garden_irrigation.source_schema import (
    migrate_irrigation_source,
)
from larenor_server.services.transport import ProbeResponse


TOKEN = "synthetic-home-assistant-token"
OPENSPRINKLER_PASSWORD = "d" * 32


def _json(value):
    return ProbeResponse(
        200,
        (("content-type", "application/json"),),
        json.dumps(value, separators=(",", ":")).encode(),
    )


class HomeAssistantFixture:
    def __init__(self, now):
        self.now = now
        self.calls = []
        self.after_first = None

    def __call__(self, base_url, **limits):
        assert base_url == "https://ha.fixture.invalid"
        assert limits == {"timeout": 5.0, "max_bytes": 65_536}
        return self

    def close(self):
        pass

    def request(self, method, path, headers=None, body=None, query_parameters=None, before_send=None):
        if before_send is not None:
            before_send()
        assert headers["Authorization"] == "Bearer " + TOKEN
        self.calls.append((method, path, body, query_parameters))
        if len(self.calls) == 1 and self.after_first is not None:
            callback, self.after_first = self.after_first, None
            callback()
        observed = datetime.fromtimestamp(
            self.now - 10, timezone.utc
        ).isoformat()
        last_reset = datetime.fromtimestamp(
            self.now - 3600, timezone.utc
        ).isoformat()
        next_reset = datetime.fromtimestamp(
            self.now + 23 * 3600, timezone.utc
        ).isoformat()
        if method == "POST":
            assert path == "/api/services/weather/get_forecasts"
            assert query_parameters == {"return_response": ""}
            assert json.loads(body) == {
                "entity_id": "weather.garden",
                "type": "hourly",
            }
            forecast_at = datetime.fromtimestamp(
                self.now + 3600, timezone.utc
            ).isoformat()
            return _json({
                "changed_states": [],
                "service_response": {
                    "weather.garden": {
                        "forecast": [{
                            "datetime": forecast_at,
                            "precipitation": 1.25,
                        }]
                    }
                },
            })
        entity = path.removeprefix("/api/states/")
        values = {
            "weather.garden": (
                "sunny",
                {
                    "temperature": 15.5,
                    "temperature_unit": "°C",
                    "wind_speed": 2.5,
                    "wind_speed_unit": "m/s",
                    "precipitation_unit": "mm",
                },
            ),
            "binary_sensor.garden_leak": (
                "off", {"device_class": "moisture"}
            ),
            "sensor.daily_irrigation_water": (
                "12.5",
                {
                    "device_class": "water",
                    "unit_of_measurement": "L",
                    "state_class": "total_increasing",
                    "last_reset": last_reset,
                    "next_reset": next_reset,
                },
            ),
            "sensor.back_soil": (
                "30", {"device_class": "moisture", "unit_of_measurement": "%"}
            ),
            "valve.back_garden": (
                "closed", {"device_class": "water"}
            ),
        }
        state, attributes = values[entity]
        return _json({
            "entity_id": entity,
            "state": state,
            "attributes": attributes,
            "last_changed": observed,
            "last_updated": observed,
        })


class OpenSprinklerReadFixture:
    def __init__(self, clock, *, mutable=False, on_complete=None):
        self.clock = clock
        self.mutable = mutable
        self.calls = []
        self.phase = "idle"
        self.boot = int(clock.now) - 100
        self.flow = 50
        self.last_run = [0, 0, 0, 0]
        self.duration = 0
        self.finish_after_snapshot = False
        self.on_complete = on_complete

    def sleep(self, seconds):
        self.clock.now += seconds

    @property
    def now(self):
        return int(self.clock.now)

    def __call__(self, base_url, **limits):
        assert base_url == "http://sprinkler.fixture.invalid"
        assert limits == {"timeout": 5.0, "max_bytes": 65_536}
        return self

    def close(self):
        pass

    def request(self, method, path, headers=None, body=None, query_parameters=None, before_send=None):
        if before_send is not None:
            before_send()
        assert method == "GET"
        assert headers == {"Accept": "application/json"}
        assert query_parameters["pw"] == OPENSPRINKLER_PASSWORD
        self.calls.append(path)
        if path == "/cm":
            assert self.mutable
            if query_parameters["en"] == "1":
                self.duration = int(query_parameters["t"])
                self.phase = "running"
            else:
                self.phase = "idle"
                self.clock.now += 1
            return _json({"result": 1})
        running = self.phase == "running"
        values = {
            "/jo": {
                "fwv": 221, "fwm": 5, "sn1t": 2,
                "fpr0": 1, "fpr1": 0,
                "mas": 0, "mas2": 0, "mas3": 0, "mas4": 0,
            },
            "/jn": {"stn_dis": [0], "stn_spe": [0]},
            "/jc": {
                "devt": self.now, "lupt": self.boot,
                "lrun": self.last_run, "sbits": [1 if running else 0],
                "ps": ([
                    [99, self.duration, self.now, 0]
                    if running else [0, 0, 0, 0]
                ] + [[0, 0, 0, 0] for _ in range(7)]),
                "flwrt": 1, "flcrt": 1 if running else 0,
                "flcto": self.flow,
                "nq": 1 if running else 0, "en": 1, "ocs": 0,
            },
            "/js": {"sn": [1 if running else 0] + [0] * 7, "nstations": 8},
        }
        result = _json(values[path])
        if path == "/jc" and running:
            self.finish_after_snapshot = True
        if path == "/js" and self.finish_after_snapshot:
            self.finish_after_snapshot = False
            self.phase = "idle"
            self.clock.now += self.duration
            self.flow += max(1, (4_000 * self.duration // 60) // 10)
            self.last_run = [0, 99, self.duration, self.now]
            if self.on_complete is not None:
                callback, self.on_complete = self.on_complete, None
                callback()
        return result


def _source(service_id, room, *, expected=None, service_revision=1):
    return {
        "schemaVersion": 1,
        "expectedRevision": expected,
        "serviceId": service_id,
        "expectedServiceRevision": service_revision,
        "weatherEntityId": "weather.garden",
        "leakEntityId": "binary_sensor.garden_leak",
        "dailyWaterEntityId": "sensor.daily_irrigation_water",
        "targetMoisturePermille": 600,
        "soilMaxAgeMs": 60_000,
        "safetyMaxAgeMs": 60_000,
        "forecastMaxAgeMs": 6 * 60 * 60 * 1000,
        "rainDeferralMilliMm": 4_000,
        "freezeThresholdMilliC": 2_000,
        "windLimitMilliMps": 12_000,
        "previewTtlMs": 30_000,
        "dailyLimitMl": 100_000,
        "priceMicrosPerLiter": 2_500_000,
        "zones": [{
            "roomId": room["ref"]["id"],
            "roomRevision": room["revision"],
            "valveEntityId": "valve.back_garden",
            "soilMoistureEntityId": "sensor.back_soil",
            "plantName": "Tomatoes",
            "flowMlPerMinute": 4_000,
            "maxDurationSeconds": 900,
        }],
    }


def _configured(server, *, controller_fixture=None):
    app, client, settings, clock = server
    pair = ready(server)
    scope = app.state.core.context
    room_response = client.post(
        f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}",
        headers=auth(pair),
        json={"kind": "room", "label": "Back garden", "order": 0},
    )
    assert room_response.status_code == 201, room_response.text
    room = room_response.json()["record"]
    created = client.post(
        "/api/v1/admin/services",
        headers=auth(pair),
        json={
            "name": "Home Assistant",
            "kind": "home_assistant",
            "baseUrl": "https://ha.fixture.invalid",
            "credentials": {"token": TOKEN},
        },
    )
    assert created.status_code == 201, created.text
    service = created.json()["service"]
    with app.state.core.db.transaction() as connection:
        migrate_irrigation_source(connection)
    fixture = HomeAssistantFixture(clock.now)
    provider = HomeAssistantIrrigationProvider(
        app.state.core.db,
        app.state.core.auth,
        app.state.core.settings,
        settings.key_file.read_bytes(),
        app.state.core.context,
        app.state.core.services._home_assistant_connection,
        app.state.core.home_resources,
        transport_factory=fixture,
        controller_transport_factory=controller_fixture,
        controller_sleep=(
            None if controller_fixture is None else controller_fixture.sleep
        ),
    )
    app.state.irrigation_gateway = build_irrigation_gateway(
        provider, clock=clock
    )
    return app, client, pair, service, room, fixture


def test_normal_source_cas_and_live_home_assistant_projection(server):
    app, client, pair, service, room, fixture = _configured(server)
    missing = client.get(
        "/api/v1/admin/irrigation-budget/source", headers=auth(pair)
    )
    assert missing.status_code == 409
    saved = client.put(
        "/api/v1/admin/irrigation-budget/source",
        headers=auth(pair),
        json=_source(service["id"], room),
    )
    assert saved.status_code == 200, saved.text
    source = saved.json()["source"]
    assert source["revision"] == 1
    assert source["serviceId"] == service["id"]
    assert source["zones"][0]["roomId"] == room["ref"]["id"]
    assert source["zones"][0]["roomRevision"] == room["revision"]
    assert TOKEN not in saved.text
    assert client.get(
        "/api/v1/admin/irrigation-budget/source", headers=auth(pair)
    ).json()["source"] == source

    response = client.get(
        "/api/v1/admin/irrigation-budget", headers=auth(pair)
    )
    assert response.status_code == 200, response.text
    snapshot = response.json()["snapshot"]
    assert snapshot["controlCapability"] == "manual_required"
    assert snapshot["commandEndpointAvailable"] is False
    assert snapshot["rainMilliMm"] == 1_250
    assert snapshot["budget"] == {
        "revision": snapshot["budget"]["revision"],
        "dailyLimitMl": 100_000,
        "usedMl": 12_500,
        "plannedMl": snapshot["budget"]["plannedMl"],
        "estimatedCostMicros": snapshot["budget"]["estimatedCostMicros"],
    }
    assert snapshot["zones"][0]["areaName"] == "Back garden"
    assert snapshot["zones"][0]["moisturePermille"] == 300
    provider = app.state.irrigation_gateway._provider
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    authority = provider.authority_for_actor(actor)
    zone = provider.policy(authority).zones[0]
    assert zone.areaId == room["ref"]["id"]
    assert zone.areaRevision == room["revision"]
    assert [call[:2] for call in fixture.calls] == [
        ("GET", "/api/states/weather.garden"),
        ("GET", "/api/states/binary_sensor.garden_leak"),
        ("GET", "/api/states/sensor.daily_irrigation_water"),
        ("GET", "/api/states/sensor.back_soil"),
        ("GET", "/api/states/valve.back_garden"),
        ("POST", "/api/services/weather/get_forecasts"),
    ]


def test_source_rejects_stale_service_and_configuration_revisions(server):
    _app, client, pair, service, room, _fixture = _configured(server)
    assert client.put(
        "/api/v1/admin/irrigation-budget/source",
        headers=auth(pair),
        json=_source(service["id"], room),
    ).status_code == 200
    stale = client.put(
        "/api/v1/admin/irrigation-budget/source",
        headers=auth(pair),
        json=_source(service["id"], room, expected=None),
    )
    assert stale.status_code == 409
    updated = client.patch(
        "/api/v1/admin/services/" + service["id"],
        headers=auth(pair),
        json={
            "expectedRevision": 1,
            "name": "Changed",
            "baseUrl": "https://ha2.fixture.invalid",
            "credentials": {"token": TOKEN},
        },
    )
    assert updated.status_code == 200
    changed = client.get(
        "/api/v1/admin/irrigation-budget", headers=auth(pair)
    )
    assert changed.status_code == 409


def test_late_source_replacement_discards_upstream_observation(server):
    app, client, pair, service, room, fixture = _configured(server)
    assert client.put(
        "/api/v1/admin/irrigation-budget/source",
        headers=auth(pair),
        json=_source(service["id"], room),
    ).status_code == 200
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    provider = app.state.irrigation_gateway._provider
    replacement = _source(service["id"], room, expected=1)
    replacement["dailyLimitMl"] = 90_000
    fixture.after_first = lambda: provider.source_store.put(actor, replacement)
    response = client.get(
        "/api/v1/admin/irrigation-budget", headers=auth(pair)
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "revision_conflict"
    assert provider.configuration(actor).revision == 2


def test_room_revision_drift_discards_upstream_observation(server):
    app, client, pair, service, room, fixture = _configured(server)
    assert client.put(
        "/api/v1/admin/irrigation-budget/source",
        headers=auth(pair),
        json=_source(service["id"], room),
    ).status_code == 200
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    scope = app.state.core.context

    def rename_room():
        app.state.core.home_resources.update(
            actor,
            scope.coreId,
            scope.homeId,
            room["ref"]["id"],
            {
                "expectedRevision": room["revision"],
                "expectedAclRevision": room["aclRevision"],
                "label": "Renamed garden",
                "order": 0,
            },
        )

    fixture.after_first = rename_room
    response = client.get(
        "/api/v1/admin/irrigation-budget", headers=auth(pair)
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "revision_conflict"


def test_admin_controller_binding_enables_only_live_verified_control(server):
    controller_fixture = OpenSprinklerReadFixture(server[3])
    app, client, pair, service, room, _fixture = _configured(
        server, controller_fixture=controller_fixture
    )
    source_response = client.put(
        "/api/v1/admin/irrigation-budget/source",
        headers=auth(pair),
        json=_source(service["id"], room),
    )
    assert source_response.status_code == 200
    manual = client.get(
        "/api/v1/admin/irrigation-budget", headers=auth(pair)
    ).json()["snapshot"]
    assert manual["controlCapability"] == "manual_required"
    zone = manual["zones"][0]

    saved = client.put(
        "/api/v1/admin/irrigation-budget/controller",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "expectedRevision": None,
            "expectedSourceRevision": 1,
            "baseUrl": "http://sprinkler.fixture.invalid",
            "passwordMd5": OPENSPRINKLER_PASSWORD,
            "stations": [{
                "zoneId": zone["zoneId"],
                "expectedZoneRevision": zone["zoneRevision"],
                "stationIndex": 0,
            }],
        },
    )
    assert saved.status_code == 200, saved.text
    metadata = saved.json()["controller"]
    assert metadata["revision"] == 1
    assert metadata["sourceRevision"] == 1
    assert metadata["endpointConfigured"] is True
    assert metadata["passwordConfigured"] is True
    assert OPENSPRINKLER_PASSWORD not in saved.text
    assert "sprinkler.fixture.invalid" not in saved.text

    controlled = client.get(
        "/api/v1/admin/irrigation-budget", headers=auth(pair)
    )
    assert controlled.status_code == 200, controlled.text
    assert controlled.json()["snapshot"]["controlCapability"] == "verified_control"
    assert controlled.json()["snapshot"]["commandEndpointAvailable"] is True
    assert controller_fixture.calls == ["/jo", "/jn", "/jc", "/js"]


def test_loopback_confirm_returns_actual_flow_receipt(server):
    controller_fixture = OpenSprinklerReadFixture(server[3], mutable=True)
    _app, client, pair, service, room, _fixture = _configured(
        server, controller_fixture=controller_fixture
    )
    assert client.put(
        "/api/v1/admin/irrigation-budget/source",
        headers=auth(pair),
        json=_source(service["id"], room),
    ).status_code == 200
    snapshot = client.get(
        "/api/v1/admin/irrigation-budget", headers=auth(pair)
    ).json()["snapshot"]
    zone = snapshot["zones"][0]
    assert client.put(
        "/api/v1/admin/irrigation-budget/controller",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "expectedRevision": None,
            "expectedSourceRevision": 1,
            "baseUrl": "http://sprinkler.fixture.invalid",
            "passwordMd5": OPENSPRINKLER_PASSWORD,
            "stations": [{
                "zoneId": zone["zoneId"],
                "expectedZoneRevision": zone["zoneRevision"],
                "stationIndex": 0,
            }],
        },
    ).status_code == 200
    controlled = client.get(
        "/api/v1/admin/irrigation-budget", headers=auth(pair)
    ).json()["snapshot"]
    assert controlled["budget"]["plannedMl"] == 30_000
    preview = client.post(
        "/api/v1/admin/irrigation-budget/preview",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": "e" * 32,
            "expectedPlanId": controlled["planId"],
            "expectedPolicyRevision": controlled["policyRevision"],
            "expectedBudgetRevision": controlled["budget"]["revision"],
        },
    )
    assert preview.status_code == 200, preview.text
    preview_value = preview.json()["preview"]
    receipt = client.post(
        "/api/v1/admin/irrigation-budget/confirm",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "previewId": preview_value["previewId"],
            "confirmToken": preview_value["confirmToken"],
        },
    )
    assert receipt.status_code == 200, receipt.text
    value = receipt.json()["receipt"]
    assert value["status"] == "applied"
    assert value["results"][0]["status"] == "applied"
    assert value["results"][0]["readback"]["flowVerified"] is True
    assert value["results"][0]["readback"]["deliveredMl"] == 30_000
    mutations = [path for path in controller_fixture.calls if path == "/cm"]
    assert mutations == ["/cm"]


def test_account_revision_drift_after_device_io_discards_applied_receipt(server):
    app = server[0]
    actor_id = None

    def change_account_revision():
        with app.state.core.db.transaction() as connection:
            connection.execute(
                "UPDATE users SET revision=revision+1 WHERE id=?", (actor_id,)
            )

    controller_fixture = OpenSprinklerReadFixture(
        server[3], mutable=True, on_complete=change_account_revision
    )
    _app, client, pair, service, room, _fixture = _configured(
        server, controller_fixture=controller_fixture
    )
    actor_id = app.state.core.auth.authenticate(pair["accessToken"]).id
    assert client.put(
        "/api/v1/admin/irrigation-budget/source",
        headers=auth(pair), json=_source(service["id"], room),
    ).status_code == 200
    snapshot = client.get(
        "/api/v1/admin/irrigation-budget", headers=auth(pair)
    ).json()["snapshot"]
    zone = snapshot["zones"][0]
    assert client.put(
        "/api/v1/admin/irrigation-budget/controller",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "expectedRevision": None,
            "expectedSourceRevision": 1,
            "baseUrl": "http://sprinkler.fixture.invalid",
            "passwordMd5": OPENSPRINKLER_PASSWORD,
            "stations": [{
                "zoneId": zone["zoneId"],
                "expectedZoneRevision": zone["zoneRevision"],
                "stationIndex": 0,
            }],
        },
    ).status_code == 200
    controlled = client.get(
        "/api/v1/admin/irrigation-budget", headers=auth(pair)
    ).json()["snapshot"]
    preview = client.post(
        "/api/v1/admin/irrigation-budget/preview",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": "f" * 32,
            "expectedPlanId": controlled["planId"],
            "expectedPolicyRevision": controlled["policyRevision"],
            "expectedBudgetRevision": controlled["budget"]["revision"],
        },
    ).json()["preview"]
    receipt = client.post(
        "/api/v1/admin/irrigation-budget/confirm",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "previewId": preview["previewId"],
            "confirmToken": preview["confirmToken"],
        },
    )
    assert receipt.status_code == 200, receipt.text
    result = receipt.json()["receipt"]
    assert result["status"] == "unknown"
    assert result["results"][0]["code"] == "worker_ack_unknown"
    assert result["results"][0]["readback"] is None
    assert [path for path in controller_fixture.calls if path == "/cm"] == ["/cm"]
