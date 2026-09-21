from dataclasses import replace

from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.ev_charging import (
    ChargeAuthority,
    ChargeDeviceCapability,
    ChargeProviderCapability,
    ChargeProviderSnapshot,
    EnergyInputs,
    EnergySlot,
    ManualOverride,
    ProviderState,
)

NOW = 1_788_206_400.0
CHARGER = "3" * 32
PREVIEW = "4" * 32
COMMAND = "5" * 32


class Charger:
    def __init__(self):
        self.core_id = ""
        self.home_id = ""
        self.applies = 0
        self.observed = None

    def apply(self, *, plan_hash, slots):
        self.applies += 1
        self.observed = plan_hash

    def readback(self):
        return self.observed


class Provider:
    def __init__(self):
        self.schedule_revision = 7
        self.tariff_revision = 5
        self.solar_revision = 6
        self.power_budget_revision = 7
        self.override_revision = 8
        self.override_until = None
        self.provider_observed_at = NOW
        self.authority_can_control = True
        self.capability_value = ChargeProviderCapability(
            "ready",
            "ocpp",
            True,
            True,
            "ready",
            (
                ChargeDeviceCapability(
                    CHARGER, "Garage charger", 4, 7, 5, 7, 40, 40_000, 16
                ),
            ),
        )

    def capability(self):
        return self.capability_value

    def snapshot(self, *, actor_id, session_family_id, charger_id):
        authority = ChargeAuthority(
            core_id=self.core_id,
            home_id=self.home_id,
            account_id=actor_id,
            session_id=session_family_id,
            core_revision=1,
            home_revision=2,
            account_revision=3,
            charger_id=charger_id,
            charger_revision=4,
            tariff_revision=self.tariff_revision,
            solar_revision=self.solar_revision,
            power_budget_revision=self.power_budget_revision,
            override_revision=self.override_revision,
            schedule_revision=self.schedule_revision,
            max_current_amp=16,
            voltage=230,
            max_session_wh=20_000,
            can_control=self.authority_can_control,
        )
        states = tuple(
            ProviderState(name, revision, "verified", self.provider_observed_at)
            for name, revision in (
                ("tariff", self.tariff_revision),
                ("solar", self.solar_revision),
                ("power_budget", self.power_budget_revision),
            )
        )
        inputs = EnergyInputs(
            tariff_revision=self.tariff_revision,
            solar_revision=self.solar_revision,
            power_budget_revision=self.power_budget_revision,
            override_revision=self.override_revision,
            provider_states=states,
            slots=(EnergySlot(NOW, NOW + 3600, 100, 0, 3680),),
            manual_override=None
            if self.override_until is None
            else ManualOverride(self.override_until, 8, "driver-control"),
        )
        return ChargeProviderSnapshot(authority, inputs)


def configured(tmp_path, *, provider=True, charger=True):
    root = tmp_path.resolve()
    clock = Clock(NOW)
    settings = Settings(
        root / "data",
        root / "secrets/vault.key",
        clock=clock,
        login_ip_limit=100,
        login_account_limit=100,
        login_global_limit=100,
    )
    source = Provider() if provider else None
    charger_source = Charger() if charger else None
    app = create_app(
        settings,
        ev_charge_provider=source,
        ev_charge_charger=charger_source,
    )
    if source is not None:
        source.core_id = app.state.core.context.coreId
        source.home_id = app.state.core.context.homeId
    return app, settings, source, charger_source


def preview_body(**updates):
    value = {
        "schemaVersion": 1,
        "previewId": PREVIEW,
        "expectedChargerRevision": 4,
        "expectedScheduleRevision": 7,
        "expectedTariffRevision": 5,
        "expectedPowerBudgetRevision": 7,
        "departureAtMs": round((NOW + 3600) * 1000),
        "targetSoc": 45,
    }
    value.update(updates)
    return value


def test_capability_is_authenticated_and_unconfigured_provider_is_explicit(tmp_path):
    app, settings, _provider, _charger = configured(tmp_path, provider=False)
    context = app.state.core.context
    root = f"/api/v1/ev-charging/{context.coreId}/{context.homeId}"
    with TestClient(app) as client:
        assert client.get(root + "/capability").status_code == 401
        pair = ready((app, client, settings, Clock(NOW)))
        value = client.get(root + "/capability", headers=auth(pair)).json()
        assert value == {
            "schemaVersion": 1,
            "coreId": context.coreId,
            "homeId": context.homeId,
            "state": "unavailable",
            "providerKind": "none",
            "canPlan": False,
            "canControl": False,
            "reason": "provider_not_configured",
            "chargers": [],
        }
        assert (
            client.post(
                root + f"/chargers/{CHARGER}/previews",
                headers=auth(pair),
                json=preview_body(),
            ).status_code
            == 503
        )


def test_provider_without_control_adapter_is_truthfully_read_only(tmp_path):
    app, settings, _provider, _charger = configured(tmp_path, charger=False)
    context = app.state.core.context
    root = f"/api/v1/ev-charging/{context.coreId}/{context.homeId}"
    with TestClient(app) as client:
        pair = ready((app, client, settings, Clock(NOW)))
        capability = client.get(root + "/capability", headers=auth(pair)).json()
        assert capability["canPlan"] is True
        assert capability["canControl"] is False
        assert capability["reason"] == "charger_read_only"
        plan = client.post(
            root + f"/chargers/{CHARGER}/previews",
            headers=auth(pair),
            json=preview_body(),
        ).json()["preview"]
        response = client.post(
            root + f"/chargers/{CHARGER}/commands",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "previewId": PREVIEW,
                "commandId": COMMAND,
                "expectedPlanHash": plan["planHash"],
                "expectedChargerRevision": 4,
                "expectedScheduleRevision": 7,
            },
        )
        assert response.status_code == 503


def test_server_derived_tariff_goal_and_battery_plan_is_revision_bound(tmp_path):
    app, settings, provider, _charger = configured(tmp_path)
    context = app.state.core.context
    root = f"/api/v1/ev-charging/{context.coreId}/{context.homeId}"
    with TestClient(app) as client:
        pair = ready((app, client, settings, Clock(NOW)))
        response = client.post(
            root + f"/chargers/{CHARGER}/previews",
            headers=auth(pair),
            json=preview_body(),
        )
        assert response.status_code == 201
        plan = response.json()["preview"]
        assert plan["accountId"] == pair["user"]["id"]
        assert plan["sessionFamilyId"] not in str(preview_body())
        assert plan["status"] == "ready"
        assert plan["requiredWh"] == 2_000
        assert plan["providerStatus"] == {
            "power_budget": "verified",
            "solar": "verified",
            "tariff": "verified",
        }
        forged = client.post(
            root + f"/chargers/{CHARGER}/previews",
            headers=auth(pair),
            json=preview_body(previewId="9" * 32, batteryCapacityWh=1),
        )
        assert forged.status_code == 400

        provider.schedule_revision = 8
        stale = client.post(
            root + f"/chargers/{CHARGER}/previews",
            headers=auth(pair),
            json=preview_body(previewId="6" * 32),
        )
        assert stale.status_code == 409
        provider.schedule_revision = 7
        unsafe = client.post(
            root + f"/chargers/{CHARGER}/previews",
            headers=auth(pair),
            json=preview_body(previewId="7" * 32, targetSoc=20),
        )
        assert unsafe.status_code in {400, 422}


def test_confirm_is_capability_gated_idempotent_and_stale_safe(tmp_path):
    app, settings, provider, charger = configured(tmp_path)
    context = app.state.core.context
    root = f"/api/v1/ev-charging/{context.coreId}/{context.homeId}"
    with TestClient(app) as client:
        pair = ready((app, client, settings, Clock(NOW)))
        plan = client.post(
            root + f"/chargers/{CHARGER}/previews",
            headers=auth(pair),
            json=preview_body(),
        ).json()["preview"]
        body = {
            "schemaVersion": 1,
            "previewId": PREVIEW,
            "commandId": COMMAND,
            "expectedPlanHash": plan["planHash"],
            "expectedChargerRevision": 4,
            "expectedScheduleRevision": 7,
        }
        first = client.post(
            root + f"/chargers/{CHARGER}/commands",
            headers=auth(pair),
            json=body,
        )
        assert first.status_code == 201
        assert first.json()["receipt"]["status"] == "awaiting_readback"
        assert (
            client.post(
                root + f"/chargers/{CHARGER}/commands",
                headers=auth(pair),
                json=body,
            ).json()
            == first.json()
        )
        assert charger.applies == 1

        provider.tariff_revision = 6
        provider.capability_value = replace(
            provider.capability_value,
            chargers=(
                replace(provider.capability_value.chargers[0], tariff_revision=6),
            ),
        )
        assert (
            client.post(
                root + f"/chargers/{CHARGER}/commands",
                headers=auth(pair),
                json={**body, "commandId": "7" * 32},
            ).status_code
            == 409
        )

        provider.capability_value = replace(
            provider.capability_value,
            state="unavailable",
            can_plan=False,
            can_control=False,
            reason="provider_unreachable",
            chargers=(),
        )
        assert (
            client.post(
                root + f"/chargers/{CHARGER}/commands",
                headers=auth(pair),
                json={**body, "commandId": "8" * 32},
            ).status_code
            == 503
        )


def test_confirm_rejects_changed_solar_override_and_stale_provider_evidence(tmp_path):
    app, settings, provider, charger = configured(tmp_path)
    context = app.state.core.context
    root = f"/api/v1/ev-charging/{context.coreId}/{context.homeId}"
    with TestClient(app) as client:
        pair = ready((app, client, settings, Clock(NOW)))
        plan = client.post(
            root + f"/chargers/{CHARGER}/previews",
            headers=auth(pair),
            json=preview_body(),
        ).json()["preview"]
        body = {
            "schemaVersion": 1,
            "previewId": PREVIEW,
            "expectedPlanHash": plan["planHash"],
            "expectedChargerRevision": 4,
            "expectedScheduleRevision": 7,
        }

        provider.solar_revision = 7
        solar = client.post(
            root + f"/chargers/{CHARGER}/commands",
            headers=auth(pair),
            json={**body, "commandId": "6" * 32},
        )
        assert solar.status_code == 409

        provider.solar_revision = 6
        provider.override_revision = 9
        provider.override_until = NOW + 300
        override = client.post(
            root + f"/chargers/{CHARGER}/commands",
            headers=auth(pair),
            json={**body, "commandId": "7" * 32},
        )
        assert override.status_code == 409

        provider.override_revision = 8
        override_same_revision = client.post(
            root + f"/chargers/{CHARGER}/commands",
            headers=auth(pair),
            json={**body, "commandId": "9" * 32},
        )
        assert override_same_revision.status_code == 409

        provider.override_until = None
        provider.provider_observed_at = NOW - 301
        stale = client.post(
            root + f"/chargers/{CHARGER}/commands",
            headers=auth(pair),
            json={**body, "commandId": "8" * 32},
        )
        assert stale.status_code == 409
        assert charger.applies == 0


def test_admin_cannot_override_provider_control_denial(tmp_path):
    app, settings, provider, charger = configured(tmp_path)
    context = app.state.core.context
    root = f"/api/v1/ev-charging/{context.coreId}/{context.homeId}"
    with TestClient(app) as client:
        pair = ready((app, client, settings, Clock(NOW)))
        plan = client.post(
            root + f"/chargers/{CHARGER}/previews",
            headers=auth(pair),
            json=preview_body(),
        ).json()["preview"]
        provider.authority_can_control = False
        response = client.post(
            root + f"/chargers/{CHARGER}/commands",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "previewId": PREVIEW,
                "commandId": COMMAND,
                "expectedPlanHash": plan["planHash"],
                "expectedChargerRevision": 4,
                "expectedScheduleRevision": 7,
            },
        )
        assert response.status_code == 403
        assert charger.applies == 0
