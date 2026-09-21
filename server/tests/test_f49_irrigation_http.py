from conftest import auth, ready

from larenor_server.garden_irrigation.runtime import build_irrigation_gateway
from test_f49_irrigation_water_budget import (
    ADMIN,
    POLICY,
    ZONE_A,
    authority,
    budget,
    forecast,
    policy,
    safety,
    soil,
    zone,
)

NOW_MS = 1_020_000


class Provider:
    def __init__(self, current_authority, current_policy):
        self.current_authority = current_authority
        self.current_policy = current_policy
        self.stale = False

    def authority(self, account_id):
        return self.current_authority

    def policy(self, current_authority):
        return self.current_policy.model_dump(mode="json")

    def policy_by_id(self, policy_id):
        return self.current_policy

    def inputs(self, actor, current_authority, current_policy):
        reading = soil().model_copy(
            update={
                "coreId": self.current_authority.coreId,
                "homeId": self.current_authority.homeId,
                "observedAtMs": 0 if self.stale else 1_000_000,
            }
        )
        return {
            "soil": [reading.model_dump(mode="json")],
            "safety": safety().model_copy(update={
                "coreId": self.current_authority.coreId,
                "homeId": self.current_authority.homeId,
            }).model_dump(mode="json"),
            "forecast": forecast().model_copy(update={
                "coreId": self.current_authority.coreId,
                "homeId": self.current_authority.homeId,
            }).model_dump(mode="json"),
            "budget": budget().model_copy(update={
                "coreId": self.current_authority.coreId,
                "homeId": self.current_authority.homeId,
            }).model_dump(mode="json"),
            "overrides": [],
        }

    def zone_labels(self, actor, current_authority, current_policy):
        return {ZONE_A: {"areaName": "Back garden", "plantName": "Tomatoes"}}

    def control_capability(self, actor, current_authority, current_policy):
        return "manual_required"


def configured(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    principal = app.state.core.auth.authenticate(pair["accessToken"])
    context = app.state.core.context
    current_zone = zone().model_copy(update={"coreId": context.coreId, "homeId": context.homeId})
    current_policy = policy().model_copy(update={
        "coreId": context.coreId,
        "homeId": context.homeId,
        "zones": [current_zone],
    })
    current_authority = authority().model_copy(update={
        "coreId": context.coreId,
        "homeId": context.homeId,
        "accountId": principal.id,
        "sessionFamilyId": principal.family_id,
    })
    provider = Provider(current_authority, current_policy)
    app.state.irrigation_gateway = build_irrigation_gateway(
        provider, clock=lambda: NOW_MS / 1000
    )
    return client, pair, provider


def test_authenticated_budget_exposes_area_plant_soil_and_no_command(server):
    client, pair, _provider = configured(server)
    assert client.get("/api/v1/admin/irrigation-budget").status_code == 401
    response = client.get("/api/v1/admin/irrigation-budget", headers=auth(pair))
    assert response.status_code == 200, response.text
    snapshot = response.json()["snapshot"]
    assert snapshot["budget"]["dailyLimitMl"] == 100_000
    assert snapshot["zones"][0]["areaName"] == "Back garden"
    assert snapshot["zones"][0]["plantName"] == "Tomatoes"
    assert snapshot["zones"][0]["moisturePermille"] == 300
    assert snapshot["controlCapability"] == "manual_required"
    assert snapshot["commandEndpointAvailable"] is False
    assert client.post("/api/v1/admin/irrigation-budget", headers=auth(pair), json={}).status_code == 405


def test_stale_soil_and_changed_account_fail_closed(server):
    client, pair, provider = configured(server)
    provider.stale = True
    stale = client.get("/api/v1/admin/irrigation-budget", headers=auth(pair))
    assert stale.status_code == 200
    assert stale.json()["snapshot"]["zones"][0]["reason"] == "soil_sensor_stale"
    provider.current_authority = provider.current_authority.model_copy(
        update={"accountId": ADMIN}
    )
    changed = client.get("/api/v1/admin/irrigation-budget", headers=auth(pair))
    assert changed.status_code in {403, 409}
