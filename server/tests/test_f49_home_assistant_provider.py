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

    def request(self, method, path, headers=None, body=None, query_parameters=None):
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


def _configured(server):
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
