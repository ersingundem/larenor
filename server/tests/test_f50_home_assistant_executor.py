import json
from types import MappingProxyType
from types import SimpleNamespace

import pytest

from larenor_server.errors import ApiError
from larenor_server.room_comfort.home_assistant import HomeAssistantComfortExecutor
from larenor_server.room_comfort.models import ComfortWorkerCommand
from larenor_server.room_comfort.source_models import (
    ComfortRoomSource,
    HomeAssistantComfortSource,
)
from larenor_server.services.service import ServiceConnection
from larenor_server.services.transport import ProbeResponse


CORE = "1" * 32
HOME = "2" * 32
ROOM = "3" * 32
AREA = "4" * 32
SERVICE = "5" * 32


def source():
    return HomeAssistantComfortSource(
        schemaVersion=1,
        revision=7,
        serviceId=SERVICE,
        serviceRevision=3,
        weatherEntityId="weather.home",
        aqiEntityId="sensor.outdoor_aqi",
        targetTemperatureMilliC=22_000,
        temperatureToleranceMilliC=1_000,
        humidityHighPermille=700,
        co2HighPpm=1_000,
        vocHighPpb=500,
        outdoorAqiLimit=100,
        freezeThresholdMilliC=3_000,
        indoorMaxAgeMs=60_000,
        outdoorMaxAgeMs=120_000,
        occupancyMaxAgeMs=60_000,
        previewTtlMs=30_000,
        rooms=[ComfortRoomSource(
            roomId=ROOM,
            roomRevision=2,
            areaId=AREA,
            areaRevision=3,
            climateEntityId="climate.living_room",
            windowEntityId="cover.living_room_window",
            temperatureEntityId="sensor.living_temperature",
            humidityEntityId="sensor.living_humidity",
            co2EntityId="sensor.living_co2",
            vocEntityId="sensor.living_voc",
            smokeEntityId="binary_sensor.living_smoke",
            occupancyEntityId="binary_sensor.living_occupancy",
        )],
    )


class Store:
    def __init__(self):
        self.value = source()
        self.service = ServiceConnection(
            id=SERVICE,
            revision=3,
            name="Home Assistant",
            kind="home_assistant",
            base_url="http://127.0.0.1:8123",
            credentials=MappingProxyType({"token": "secret"}),
        )
        self.effect_current = True

    def get(self):
        return self.value

    def resolve(self, expected):
        if expected != self.value:
            raise ApiError("revision_conflict", 409)
        return self.service

    def reserve_effect(self, actor, expected):
        if not self.effect_current or expected != self.value:
            raise ApiError("invalid_session", 401)
        return (
            self.value, self.service, actor.id, 1, actor.family_id,
            actor.token_id,
        )

    def assert_effect_current(self, actor, expected):
        if not self.effect_current or self.reserve_effect(actor, self.value) != expected:
            raise ApiError("invalid_session", 401)


class Transport:
    responses = []
    calls = []
    revoke_after_get = None

    def __init__(self, base_url, **_kwargs):
        assert base_url == "http://127.0.0.1:8123"

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None

    def request(self, method, path, *, headers, body=None, before_send=None):
        before_send()
        self.calls.append((method, path, headers, body))
        response = self.responses.pop(0)
        if method == "GET" and self.revoke_after_get is not None:
            self.revoke_after_get()
        return response


def response(value):
    return ProbeResponse(
        status=200,
        headers=(("content-type", "application/json"),),
        body=json.dumps(value).encode(),
    )


def state(entity, value, timestamp):
    return {
        "entity_id": entity,
        "state": value,
        "attributes": {},
        "last_updated": timestamp,
    }


def test_climate_executor_uses_fixed_service_and_exact_post_mutation_readback():
    store = Store()
    executor = HomeAssistantComfortExecutor(
        store, transport_factory=Transport
    )
    device = executor.device(store.value, store.value.rooms[0], "hvac")
    before_at = "2026-09-30T10:00:00+00:00"
    after_at = "2026-09-30T10:00:01+00:00"
    before_ms = 1790762400000
    Transport.calls = []
    Transport.revoke_after_get = None
    Transport.responses = [
        response(state("climate.living_room", "off", before_at)),
        ProbeResponse(200, (("content-type", "application/json"),), b"[]"),
        response(state("climate.living_room", "heat", after_at)),
    ]
    command = ComfortWorkerCommand(
        schemaVersion=1,
        commandId="6" * 32,
        requestId="7" * 32,
        planId="8" * 32,
        policyRevision=7,
        actorAccountId="9" * 32,
        roomId=ROOM,
        targetKind="hvac",
        device=device,
        expectedStateRevision=before_ms,
        desiredState="heat",
    )

    result = executor(command)

    assert result.state == "heat"
    assert result.stateRevision == before_ms + 1000
    assert [(method, path) for method, path, *_ in Transport.calls] == [
        ("GET", "/api/states/climate.living_room"),
        ("POST", "/api/services/climate/set_hvac_mode"),
        ("GET", "/api/states/climate.living_room"),
    ]
    assert json.loads(Transport.calls[1][3]) == {
        "entity_id": "climate.living_room",
        "hvac_mode": "heat",
    }
    assert all(call[2]["Authorization"] == "Bearer secret" for call in Transport.calls)


def test_revoked_initiating_session_after_readback_sends_zero_mutation_posts():
    store = Store()
    executor = HomeAssistantComfortExecutor(store, transport_factory=Transport)
    device = executor.device(store.value, store.value.rooms[0], "hvac")
    before_at = "2026-09-30T10:00:00+00:00"
    before_ms = 1790762400000
    Transport.calls = []
    Transport.responses = [
        response(state("climate.living_room", "off", before_at)),
    ]
    Transport.revoke_after_get = staticmethod(
        lambda: setattr(store, "effect_current", False)
    )
    command = ComfortWorkerCommand(
        schemaVersion=1,
        commandId="a" * 32,
        requestId="b" * 32,
        planId="c" * 32,
        policyRevision=7,
        actorAccountId="d" * 32,
        roomId=ROOM,
        targetKind="hvac",
        device=device,
        expectedStateRevision=before_ms,
        desiredState="heat",
    )
    actor = SimpleNamespace(
        id="d" * 32, family_id="e" * 32, token_id="f" * 32
    )

    with pytest.raises(ApiError) as error:
        executor.execute_authorized(command, actor)

    assert error.value.code == "invalid_session"
    assert [method for method, *_ in Transport.calls] == ["GET"]
    assert all(method != "POST" for method, *_ in Transport.calls)
    Transport.revoke_after_get = None


def test_executor_rejects_foreign_binding_before_network():
    store = Store()
    executor = HomeAssistantComfortExecutor(store, transport_factory=Transport)
    device = executor.device(store.value, store.value.rooms[0], "hvac").model_copy(
        update={"bindingRevision": 8}
    )
    command = ComfortWorkerCommand(
        schemaVersion=1,
        commandId="6" * 32,
        requestId="7" * 32,
        planId="8" * 32,
        policyRevision=7,
        actorAccountId="9" * 32,
        roomId=ROOM,
        targetKind="hvac",
        device=device,
        expectedStateRevision=1,
        desiredState="heat",
    )
    Transport.calls = []

    with pytest.raises(ApiError, match="revision_conflict"):
        executor(command)
    assert Transport.calls == []
