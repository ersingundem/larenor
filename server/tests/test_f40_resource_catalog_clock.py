"""Catalog HMACs must retain their representation through SQLite REAL storage."""
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.config import Settings


def test_integral_clock_default_catalog_survives_normal_core_restart(tmp_path):
    settings = Settings(tmp_path / "data", tmp_path / "secrets/vault.key", clock=lambda: 2000)
    for _ in range(2):
        app = create_app(settings)
        with TestClient(app) as client:
            assert client.get("/api/v1/health").status_code == 200
            revision, resources = app.state.core.resource_reservations.catalog.list()
            assert revision == 1
            assert len(resources) == 1


def test_integral_clock_catalog_command_replay_and_restart_keep_verified_history(server):
    app, client, settings, clock = server
    actor = ready(server)
    clock.now = int(clock.now)
    scope = app.state.core.context
    root = f"/api/v1/resource-reservations/{scope.coreId}/{scope.homeId}/resources"
    command = {"schemaVersion": 1, "commandId": "17" * 16,
               "expectedCatalogRevision": 1, "label": "Integral clock resource",
               "timezone": "UTC", "capacity": 1}
    first = client.post(root + "/commands/create", headers=auth(actor), json=command)
    replay = client.post(root + "/commands/create", headers=auth(actor), json=command)
    assert first.status_code == replay.status_code == 200
    assert first.json() == replay.json()
    with TestClient(create_app(settings)) as restarted:
        result = restarted.get(root, headers=auth(actor))
        assert result.status_code == 200
        assert result.json()["catalogRevision"] == 2
        assert len(result.json()["resources"]) == 2
