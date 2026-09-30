import json
import os

from fastapi.testclient import TestClient
import pytest
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.errors import StartupError
from larenor_server.mesh_center import Zigbee2MqttObservation
from larenor_server.mesh_center.worker_ipc import MeshWorkerError
from larenor_server.runtime import create_configured_app

from conftest import auth, bootstrap_password, login


class Provider:
    def snapshot(self, actor):
        raise AssertionError("unused")

    def authority(self, account_id):
        raise AssertionError("unused")

    def topology(self, home_id):
        raise AssertionError("unused")

    def interference(self, home_id):
        raise AssertionError("unused")

    def catalog(self, catalog_id):
        raise AssertionError("unused")

    def signing_key(self, key_id):
        raise AssertionError("unused")

    def install(self, command):
        raise AssertionError("unused")


def test_configured_provider_is_wired_with_private_durable_state(tmp_path):
    root = tmp_path.resolve()
    settings = Settings(root / "data", root / "secrets/vault.key")
    app = create_app(settings, mesh_center_provider=Provider())

    with TestClient(app):
        assert app.state.mesh_center_gateway is app.state.core.mesh_center
        state = settings.data_dir / "mesh-firmware-updates.state"
        app.state.core.mesh_center._updates._store.save(
            {"schemaVersion": 1, "commands": [], "audit": []}
        )
        assert state.stat().st_mode & 0o777 == 0o600


class Observer:
    def observe(self, *, timeout=8.0):
        return Zigbee2MqttObservation(
            revision=17,
            capturedAtMs=2_000_000,
            bridgeState=b'{"state":"online"}',
            bridgeInfo=json.dumps(
                {
                    "coordinator": {
                        "ieee_address": "0x00124b00120144ae",
                        "meta": {"majorrel": 2, "minorrel": 7, "maintrel": 2},
                    },
                    "network": {"channel": 15},
                }
            ).encode(),
            devices=b"[]",
            deviceStates={},
            availability={},
        )


def test_normal_core_observer_composition_uses_current_admin_authority(tmp_path):
    root = tmp_path.resolve()
    settings = Settings(root / "data", root / "secrets/vault.key", clock=lambda: 2_000)
    app = create_app(settings, mesh_center_observer=Observer())

    with TestClient(app) as client:
        password = bootstrap_password(settings)
        initial = login(client, "admin", password).json()
        changed = client.post(
            "/api/v1/auth/password",
            headers=auth(initial),
            json={
                "currentPassword": password,
                "newPassword": "Synthetic new password 2026",
            },
        )
        credentials = changed.json()
        context = app.state.core.context
        response = client.get(
            f"/api/v1/admin/mesh-center/{context.coreId}/{context.homeId}",
            headers=auth(credentials),
        )

    assert response.status_code == 200
    snapshot = response.json()["snapshot"]
    assert snapshot["authority"]["accountId"] == credentials["user"]["id"]
    assert snapshot["authority"]["canObserveMesh"] is True
    assert snapshot["authority"]["canUpdateMesh"] is False
    assert snapshot["topology"]["devices"] == []


def test_explicit_test_provider_keeps_priority_over_observer(tmp_path):
    root = tmp_path.resolve()
    settings = Settings(root / "data", root / "secrets/vault.key")
    provider = Provider()
    app = create_app(
        settings,
        mesh_center_provider=provider,
        mesh_center_observer=object(),
    )

    with TestClient(app):
        assert app.state.core._mesh_center_provider is provider


def test_configured_worker_recovers_after_startup_outage_without_core_restart(
    tmp_path, monkeypatch
):
    class UnavailableWorker:
        available = False

        def __init__(self, *_args, **_kwargs):
            pass

        def observe(self, *, timeout=8.0):
            if not self.available:
                raise MeshWorkerError()
            return Observer().observe(timeout=timeout)

    monkeypatch.setattr(
        "larenor_server.runtime.Zigbee2MqttWorkerClient", UnavailableWorker
    )
    root = tmp_path.resolve()
    settings = Settings(
        root / "data",
        root / "secrets/vault.key",
        clock=lambda: 2_000,
        mesh_center_worker_socket=root / "mesh.sock",
        mesh_center_worker_uid=os.geteuid(),
    )

    app = create_configured_app(settings)
    with TestClient(app) as client:
        password = bootstrap_password(settings)
        initial = login(client, "admin", password).json()
        changed = client.post(
            "/api/v1/auth/password",
            headers=auth(initial),
            json={
                "currentPassword": password,
                "newPassword": "Synthetic new password 2026",
            },
        ).json()
        context = app.state.core.context
        route = f"/api/v1/admin/mesh-center/{context.coreId}/{context.homeId}"

        assert client.get(route, headers=auth(changed)).status_code == 503
        UnavailableWorker.available = True
        recovered = client.get(route, headers=auth(changed))

    assert recovered.status_code == 200
    assert recovered.json()["snapshot"]["topology"]["devices"] == []


def test_mesh_worker_settings_are_exact_and_cannot_leave_orphan_uid(
    tmp_path, monkeypatch
):
    root = tmp_path.resolve()
    socket_path = root / "mesh.sock"
    monkeypatch.setenv("LARENOR_DATA_DIR", str(root / "data"))
    monkeypatch.setenv("LARENOR_KEY_FILE", str(root / "secrets/vault.key"))
    monkeypatch.setenv("LARENOR_MESH_WORKER_SOCKET", str(socket_path))
    monkeypatch.setenv("LARENOR_MESH_WORKER_UID", str(os.geteuid()))

    settings = Settings.from_environment()

    assert settings.mesh_center_worker_socket == socket_path
    assert settings.mesh_center_worker_uid == os.geteuid()
    monkeypatch.delenv("LARENOR_MESH_WORKER_SOCKET")
    with pytest.raises(StartupError, match="invalid_worker_configuration"):
        Settings.from_environment()
