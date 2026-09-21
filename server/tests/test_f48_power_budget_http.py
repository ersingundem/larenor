from dataclasses import replace

from conftest import auth, ready

from larenor_server.power_budget.runtime import build_power_budget_gateway
from larenor_server.power_budget.service import (
    BudgetAuthority,
    BudgetInputs,
    LoadState,
    ProviderState,
)

NOW = 1_800_000_000.0


class Provider:
    def __init__(self, authority):
        self.current = authority
        self.stale = False

    def authority(self, actor):
        return self.current

    def inputs(self, actor, authority):
        return BudgetInputs(
            meter_revision=11,
            tariff_revision=13,
            load_registry_revision=17,
            grid_limit_revision=19,
            override_revision=23,
            grid_limit_w=8_000,
            grid_import_w=11_500,
            tariff_micros_per_kwh=1_250_000,
            provider_states=(
                ProviderState("meter", 11, "stale" if self.stale else "verified", NOW),
                ProviderState("tariff", 13, "verified", NOW),
            ),
            loads=(
                LoadState("medical-fridge", 1, 100, 500, True, False, 0),
                LoadState("ev-charger", 2, 10, 3_000, False, True, 0),
                LoadState("dryer", 4, 20, 2_000, False, True, 0),
            ),
            manual_override=None,
        )

    def load_labels(self, actor, authority):
        return {
            "medical-fridge": "Medical fridge",
            "ev-charger": "EV charger",
            "dryer": "Dryer",
        }

    def control_capability(self, actor, authority):
        return "manual_required"

    def apply(self, *, plan_hash, actions):
        raise AssertionError("HTTP recommendation route must never dispatch")

    def readback(self):
        raise AssertionError("HTTP recommendation route must never read commands")


def configured(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    principal = app.state.core.auth.authenticate(pair["accessToken"])
    context = app.state.core.context
    authority = BudgetAuthority(
        core_id=context.coreId,
        home_id=context.homeId,
        account_id=principal.id,
        session_id=principal.family_id,
        core_revision=3,
        home_revision=5,
        account_revision=7,
        meter_id="meter-main",
        meter_revision=11,
        tariff_revision=13,
        load_registry_revision=17,
        grid_limit_revision=19,
        override_revision=23,
        plan_revision=31,
        max_grid_w=12_000,
        max_shed_w=8_000,
        can_control=True,
    )
    provider = Provider(authority)
    app.state.power_budget_gateway = build_power_budget_gateway(
        provider,
        database=app.state.core.db,
        master_key=b"p" * 32,
        clock=lambda: NOW,
    )
    return client, pair, provider


def test_authenticated_snapshot_is_bounded_and_never_dispatches(server):
    client, pair, _provider = configured(server)
    assert client.get("/api/v1/admin/power-budget").status_code == 401
    response = client.get("/api/v1/admin/power-budget", headers=auth(pair))
    assert response.status_code == 200, response.text
    snapshot = response.json()["snapshot"]
    assert snapshot["measurement"] == {
        "gridImportW": 11_500,
        "gridLimitW": 8_000,
        "tariffMicrosPerKwh": 1_250_000,
        "providerStatus": {"meter": "verified", "tariff": "verified"},
    }
    assert [(item["label"], item["reductionW"]) for item in snapshot["plan"]["actions"]] == [
        ("EV charger", 3_000),
        ("Dryer", 500),
    ]
    assert snapshot["controlCapability"] == "manual_required"
    assert snapshot["commandEndpointAvailable"] is False
    assert client.post("/api/v1/admin/power-budget", headers=auth(pair), json={}).status_code == 405


def test_stale_provider_and_authority_drift_fail_closed(server):
    client, pair, provider = configured(server)
    provider.stale = True
    stale = client.get("/api/v1/admin/power-budget", headers=auth(pair))
    assert stale.status_code == 409
    assert stale.json()["error"]["code"] == "power_inputs_unverified"
    provider.stale = False
    provider.current = replace(provider.current, account_id="another-account")
    changed = client.get("/api/v1/admin/power-budget", headers=auth(pair))
    assert changed.status_code == 409
    assert changed.json()["error"]["code"] == "power_authority_changed"
