from dataclasses import dataclass

from fastapi.testclient import TestClient

from conftest import auth, bootstrap_password
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.energy_priorities import (
    BatteryInput,
    EnergyInputs,
    InverterReadback,
    MeterInput,
    ReservePolicy,
    SolarForecastInput,
    TariffInput,
)


METER, FORECAST, TARIFF = "5" * 32, "6" * 32, "7" * 32
BATTERY, INVERTER = "8" * 32, "9" * 32


@dataclass
class Clock:
    now: float = 1788609600.0

    def __call__(self):
        return self.now


class Provider:
    revision = 1

    def __call__(self, authority):
        now = 1_788_609_600_000
        return EnergyInputs(
            schemaVersion=1,
            coreId=authority.coreId,
            homeId=authority.homeId,
            homeRevision=authority.homeRevision,
            meter=MeterInput(
                schemaVersion=1,
                resourceId=METER,
                revision=self.revision,
                providerRevision=1,
                capturedAtMs=now,
                gridImportPowerW=200,
                gridExportPowerW=0,
            ),
            forecast=SolarForecastInput(
                schemaVersion=1,
                resourceId=FORECAST,
                revision=self.revision,
                providerRevision=2,
                generatedAtMs=now,
                startsAtMs=now,
                slotDurationSeconds=3600,
                solarEnergyWh=[3000, 0],
                loadEnergyWh=[1000, 2000],
            ),
            tariff=TariffInput(
                schemaVersion=1,
                resourceId=TARIFF,
                revision=self.revision,
                startsAtMs=now,
                slotDurationSeconds=3600,
                importPriceMicrosPerKwh=[100000, 400000],
                exportPriceMicrosPerKwh=[50000, 50000],
            ),
            battery=BatteryInput(
                schemaVersion=1,
                resourceId=BATTERY,
                revision=self.revision,
                providerRevision=3,
                capturedAtMs=now,
                capacityWh=10000,
                stateOfChargeWh=5000,
                minimumSocWh=1000,
                maximumSocWh=9000,
                maxChargePowerW=2000,
                maxDischargePowerW=1000,
            ),
            reserve=ReservePolicy(
                schemaVersion=1,
                revision=self.revision,
                backupReservePercent=40,
            ),
            manualOverride=None,
        )


def _ready(client, settings):
    password = bootstrap_password(settings)
    initial = client.post(
        "/api/v1/auth/login",
        json={"username": "admin", "password": password, "deviceName": "tablet"},
    ).json()
    response = client.post(
        "/api/v1/auth/password",
        headers=auth(initial),
        json={
            "currentPassword": password,
            "newPassword": "Synthetic new password 2026",
        },
    )
    assert response.status_code == 200
    return response.json()


def _open(tmp_path, provider, worker=None):
    clock = Clock()
    settings = Settings(
        tmp_path / "data",
        tmp_path / "secrets/vault.key",
        clock=clock,
        login_ip_limit=100,
        login_account_limit=100,
        login_global_limit=100,
    )
    app = create_app(
        settings,
        energy_priority_provider=provider,
        energy_priority_inverter_worker=worker,
    )
    return app, settings, TestClient(app)


def test_authenticated_plan_exposes_exact_advisory_and_percentage_reserve(tmp_path):
    provider = Provider()
    app, settings, client = _open(tmp_path, provider)
    with client:
        pair = _ready(client, settings)
        context = app.state.core.context
        root = f"/api/v1/energy-priorities/{context.coreId}/{context.homeId}"
        assert client.get(root).status_code == 401
        response = client.get(root, headers=auth(pair))
        assert response.status_code == 200
        body = response.json()
        assert body["authority"]["canControl"] is False
        assert body["inputs"]["reserve"]["backupReservePercent"] == 40
        assert body["plan"]["advisory"] is True
        assert body["plan"]["automaticExecutionAllowed"] is False
        assert body["plan"]["slots"][0]["action"] == "charge"


def test_preview_is_capability_gated_and_stale_provider_revision_fails_closed(tmp_path):
    provider = Provider()
    app, settings, client = _open(tmp_path, provider)
    with client:
        pair = _ready(client, settings)
        context = app.state.core.context
        root = f"/api/v1/energy-priorities/{context.coreId}/{context.homeId}"
        snapshot = client.get(root, headers=auth(pair)).json()
        command = {
            "schemaVersion": 1,
            "requestId": "a" * 32,
            "planId": snapshot["plan"]["planId"],
            "inputDigest": snapshot["plan"]["inputDigest"],
            "slotIndex": 0,
            "inverterId": INVERTER,
            "expectedInverterRevision": 1,
            "expectedAccountRevision": snapshot["authority"]["accountRevision"],
            "expectedHomeRevision": snapshot["authority"]["homeRevision"],
        }
        assert client.post(f"{root}/previews", headers=auth(pair), json=command).status_code == 403

    def worker(command):
        return InverterReadback(
            schemaVersion=1,
            requestId=command.requestId,
            coreId=command.coreId,
            homeId=command.homeId,
            inverterId=command.inverterId,
            inverterRevision=command.expectedInverterRevision,
            batteryId=command.batteryId,
            batteryRevision=command.expectedBatteryRevision,
            inputDigest=command.inputDigest,
            targetPowerW=command.targetPowerW,
            observedPowerW=command.targetPowerW,
            status="applied",
        )

    app, settings, client = _open(tmp_path / "enabled", provider, worker)
    with client:
        pair = _ready(client, settings)
        context = app.state.core.context
        root = f"/api/v1/energy-priorities/{context.coreId}/{context.homeId}"
        snapshot = client.get(root, headers=auth(pair)).json()
        provider.revision += 1
        command["planId"] = snapshot["plan"]["planId"]
        command["inputDigest"] = snapshot["plan"]["inputDigest"]
        command["expectedAccountRevision"] = snapshot["authority"]["accountRevision"]
        stale = client.post(f"{root}/previews", headers=auth(pair), json=command)
        assert (stale.status_code, stale.json()["error"]["code"]) == (409, "revision_conflict")


def test_confirm_requires_explicit_token_and_exact_readback(tmp_path):
    provider = Provider()

    def worker(command):
        return InverterReadback(
            schemaVersion=1,
            requestId=command.requestId,
            coreId=command.coreId,
            homeId=command.homeId,
            inverterId=command.inverterId,
            inverterRevision=command.expectedInverterRevision,
            batteryId=command.batteryId,
            batteryRevision=command.expectedBatteryRevision,
            inputDigest=command.inputDigest,
            targetPowerW=command.targetPowerW,
            observedPowerW=command.targetPowerW,
            status="applied",
        )

    app, settings, client = _open(tmp_path, provider, worker)
    with client:
        pair = _ready(client, settings)
        context = app.state.core.context
        root = f"/api/v1/energy-priorities/{context.coreId}/{context.homeId}"
        snapshot = client.get(root, headers=auth(pair)).json()
        body = {
            "schemaVersion": 1,
            "requestId": "b" * 32,
            "planId": snapshot["plan"]["planId"],
            "inputDigest": snapshot["plan"]["inputDigest"],
            "slotIndex": 0,
            "inverterId": INVERTER,
            "expectedInverterRevision": 1,
            "expectedAccountRevision": snapshot["authority"]["accountRevision"],
            "expectedHomeRevision": snapshot["authority"]["homeRevision"],
        }
        preview = client.post(f"{root}/previews", headers=auth(pair), json=body).json()
        denied = client.post(
            f"{root}/previews/{body['requestId']}/confirm",
            headers=auth(pair),
            json={"schemaVersion": 1, "confirmationToken": "0" * 64},
        )
        assert denied.status_code == 400
        confirmed = client.post(
            f"{root}/previews/{body['requestId']}/confirm",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "confirmationToken": preview["confirmationToken"],
            },
        )
        assert confirmed.status_code == 200
        assert confirmed.json()["readbackVerified"] is True
        readback = client.get(
            f"{root}/commands/{body['requestId']}", headers=auth(pair)
        )
        assert readback.json() == confirmed.json()
