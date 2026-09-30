import json

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.auth import Principal
from larenor_server.ev_charging.service import EnergyInputs, EnergySlot, ProviderState
from larenor_server.evcc.provider import (
    EvccBinding,
    EvccConnection,
    EvccEnergyProjection,
    EvccHttpReader,
    EvccProviderError,
    EvccRuntimeProviders,
)
from larenor_server.services.probe import probe_connection
from larenor_server.services.service import ServiceConnection
from larenor_server.services.transport import ProbeResponse


NOW = 1_800_000_000.0
SERVICE_ID = "a" * 32


def state_fixture(**updates):
    value = {
        "version": "0.214.1",
        "startupCompleted": True,
        "apiReady": True,
        "gridConfigured": True,
        "currency": "EUR",
        "grid": {"power": 4210.4},
        "tariffGrid": 0.312345,
        "circuits": {
            "main": {
                "name": "main",
                "title": "Main circuit",
                "power": 4210.4,
                "maxPower": 11000,
            }
        },
        "hems": {
            "config": {"configured": True},
            "status": {
                "dimmed": True,
                "curtailed": 100,
                "maxConsumptionPower": 8400,
            },
        },
        "vehicles": {"car": {"title": "Car", "capacity": 64}},
        "loadpoints": [
            {
                "name": "garage",
                "title": "Garage",
                "chargePower": 3680.2,
                "priority": 20,
                "connected": True,
                "charging": True,
                "vehicleName": "car",
                "vehicleSoc": 41,
                "maxCurrent": 16,
                "minCurrent": 6,
                "phasesActive": 1,
                "chargeVoltages": [230],
                "mode": "smart",
            }
        ],
    }
    value.update(updates)
    return value


class Transport:
    calls = []
    payload = state_fixture()

    def __init__(self, base_url, *, timeout, max_bytes):
        self.base_url = base_url
        self.timeout = timeout
        self.max_bytes = max_bytes

    def request(self, method, path, headers=None, body=None, **kwargs):
        self.calls.append((self.base_url, method, path, dict(headers or {}), body, kwargs))
        return ProbeResponse(
            200,
            (("Content-Type", "application/json; charset=utf-8"),),
            json.dumps(self.payload, separators=(",", ":")).encode(),
        )

    def close(self):
        pass


def connection():
    return EvccConnection(
        service_id=SERVICE_ID,
        revision=7,
        base_url="https://evcc.lan",
        api_key="evcc_test-key",
    )


def actor():
    return Principal("b" * 32, "admin", "admin", False, "c" * 32, "d" * 32)


def test_reader_uses_only_fixed_state_route_and_projects_actual_limit():
    Transport.calls = []
    value = EvccHttpReader(lambda: NOW, transport_factory=Transport).state(connection())
    assert value.grid_import_w == 4210
    assert value.physical_grid_limit_w == 11000
    assert value.grid_limit_w == 8400
    assert value.tariff_micros_per_kwh == 312345
    assert value.loadpoints[0].charge_power_w == 3680
    assert value.loadpoints[0].vehicle_capacity_wh == 64000
    assert Transport.calls == [
        (
            "https://evcc.lan",
            "GET",
            "/api/state",
            {"Accept": "application/json", "Authorization": "Bearer evcc_test-key"},
            None,
            {},
        )
    ]


def test_hems_effective_limit_does_not_relabel_actual_load_as_protocol_failure():
    Transport.payload = state_fixture(
        hems={
            "config": {"configured": True},
            "status": {
                "dimmed": True,
                "curtailed": 100,
                "maxConsumptionPower": 3000,
            },
        }
    )
    value = EvccHttpReader(lambda: NOW, transport_factory=Transport).state(connection())
    assert value.physical_grid_limit_w == 11000
    assert value.grid_limit_w == 3000
    assert value.loadpoints[0].charge_power_w == 3680


def test_evcc_connection_repr_redacts_endpoint_and_key():
    value = repr(connection())
    assert "evcc.lan" not in value
    assert "evcc_test-key" not in value
    binding = EvccBinding(
        "core", "home", 1, 1, lambda _actor: 1, connection(), lambda: None
    )
    assert "evcc.lan" not in repr(binding)
    assert "evcc_test-key" not in repr(binding)


def test_service_probe_is_reachable_but_does_not_claim_authentication():
    Transport.calls = []
    value = probe_connection(
        ServiceConnection(
            SERVICE_ID,
            "evcc",
            "evcc",
            "https://evcc.lan",
            7,
            {"apiKey": "evcc_test-key"},
        ),
        transport_factory=Transport,
    )
    assert value.state == "reachable"
    assert value.version == "0.214.1"
    assert Transport.calls[0][2:4] == (
        "/api/state",
        {"Authorization": "Bearer evcc_test-key"},
    )


@pytest.mark.parametrize(
    "payload",
    [
        {**state_fixture(), "grid": {"power": float("nan")}},
        {**state_fixture(), "tariffGrid": "0.2"},
        {**state_fixture(), "tariffGrid": -0.05},
        {**state_fixture(), "circuits": {}},
        {**state_fixture(), "loadpoints": []},
    ],
)
def test_reader_rejects_missing_or_unbounded_provider_facts(payload):
    Transport.payload = payload
    with pytest.raises(EvccProviderError, match="provider_protocol_changed"):
        EvccHttpReader(lambda: NOW, transport_factory=Transport).state(connection())
    Transport.payload = state_fixture()


class Windows:
    def projection(self, observation):
        revision = observation.state_revision
        return EvccEnergyProjection(
            19,
            EnergyInputs(
                tariff_revision=revision,
                solar_revision=13,
                power_budget_revision=observation.grid_limit_revision,
                override_revision=17,
                provider_states=(
                    ProviderState("tariff", revision, "verified", observation.observed_at),
                    ProviderState("solar", 13, "verified", observation.observed_at),
                    ProviderState(
                        "power_budget",
                        observation.grid_limit_revision,
                        "verified",
                        observation.observed_at,
                    ),
                ),
                slots=(EnergySlot(NOW, NOW + 3600, 312345, 0, 3680),),
                manual_override=None,
            ),
        )


def providers():
    binding = EvccBinding(
        core_id="core",
        home_id="home",
        core_revision=2,
        home_revision=3,
        account_revision=lambda principal: 5 if principal.id == "b" * 32 else 0,
        connection=connection(),
        validate_connection=lambda: None,
    )
    return EvccRuntimeProviders(
        binding,
        clock=lambda: NOW,
        energy_windows=Windows(),
        transport_factory=Transport,
    )


def test_power_budget_projection_is_read_only_and_revision_bound():
    Transport.payload = state_fixture()
    provider = providers().power_budget
    authority = provider.authority(actor())
    inputs = provider.inputs(actor(), authority)
    assert authority.can_control is False
    assert authority.max_grid_w == 11000
    assert authority.max_shed_w == 8400
    assert inputs.grid_limit_w == 8400
    assert inputs.grid_import_w == 4210
    assert inputs.loads[0].current_w == 3680
    assert inputs.loads[0].controllable is False
    assert provider.control_capability(actor(), authority) == "read_only"
    with pytest.raises(EvccProviderError, match="provider_read_only"):
        provider.apply(plan_hash="f" * 64, actions=())


def test_service_binding_drift_fails_before_another_upstream_read():
    current = {"valid": True}

    def validate():
        if not current["valid"]:
            raise RuntimeError("changed")

    binding = EvccBinding(
        "core",
        "home",
        1,
        1,
        lambda _actor: 1,
        connection(),
        validate,
    )
    provider = EvccRuntimeProviders(
        binding, clock=lambda: NOW, transport_factory=Transport
    ).power_budget
    provider.authority(actor())
    calls = len(Transport.calls)
    current["valid"] = False
    with pytest.raises(EvccProviderError, match="provider_binding_changed"):
        provider.authority(actor())
    assert len(Transport.calls) == calls


def test_ev_charge_projection_uses_real_charger_facts_and_external_windows():
    Transport.payload = state_fixture()
    provider = providers().ev_charging
    capability = provider.capability()
    assert capability.provider_kind == "evcc"
    assert capability.can_plan is True
    assert capability.can_control is False
    assert capability.reason == "charger_read_only"
    device = capability.chargers[0]
    assert device.current_soc == 41
    assert device.battery_capacity_wh == 64000
    snapshot = provider.snapshot(
        actor_id=actor().id,
        session_family_id=actor().family_id,
        charger_id=device.charger_id,
    )
    assert snapshot.authority.account_revision == 5
    assert snapshot.authority.can_control is False
    assert snapshot.inputs.slots[0].home_budget_w == 3680


def test_no_vehicle_capacity_means_no_plannable_charger():
    value = state_fixture(vehicles={})
    Transport.payload = value
    capability = providers().ev_charging.capability()
    assert capability.state == "unavailable"
    assert capability.can_plan is False
    assert capability.chargers == ()
    Transport.payload = state_fixture()


def test_verified_single_evcc_service_is_wired_on_normal_restart(server):
    app, client, settings, _clock = server
    pair = ready(server)
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
    with TestClient(create_app(settings)) as restarted:
        core = restarted.app.state.core
        assert core.power_budget is not None
        assert core.ev_charging.provider.__class__.__name__ == "EvccChargeProvider"
        capability = core.ev_charging.provider.capability()
        assert capability.provider_kind == "evcc"
        assert capability.can_plan is False
        assert capability.can_control is False
