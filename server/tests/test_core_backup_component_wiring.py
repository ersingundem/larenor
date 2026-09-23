"""S09.1 application wiring for the privileged component backup boundary."""

from contextlib import contextmanager

from conftest import auth, ready
from fastapi.testclient import TestClient

from larenor_server.config import Settings
from larenor_server.core_backups.service import ComponentVolumeSnapshot
from larenor_server.runtime import create_configured_app


class ComponentBoundary:
    def __init__(self):
        self.entered = 0
        self.released = 0

    @contextmanager
    def quiesce(self, _deadline):
        self.entered += 1
        try:
            yield (
                ComponentVolumeSnapshot(
                    serviceId="jellyfin",
                    serviceVersion="10.11.11",
                    configSchemaVersion=1,
                    dataSchemaVersion="upstream_managed_unverified",
                    volumeId="jellyfin-cache",
                    payload=b"synthetic cache snapshot\n",
                ),
                ComponentVolumeSnapshot(
                    serviceId="jellyfin",
                    serviceVersion="10.11.11",
                    configSchemaVersion=1,
                    dataSchemaVersion="upstream_managed_unverified",
                    volumeId="jellyfin-config",
                    payload=b"synthetic config snapshot\n",
                ),
            )
        finally:
            self.released += 1


def test_configured_app_wires_component_boundary_into_real_backup_route(tmp_path):
    root = tmp_path.resolve()
    settings = Settings(root / "data", root / "secrets/vault.key")
    boundary = ComponentBoundary()
    app = create_configured_app(
        settings,
        component_backup_boundary=boundary,
    )

    with TestClient(app) as client:
        pair = ready((app, client, settings, None))
        response = client.get(
            "/api/v1/admin/backups/plan",
            headers=auth(pair),
        )

    assert response.status_code == 200
    manifest = response.json()["manifest"]
    assert [component["serviceId"] for component in manifest["components"]] == [
        "jellyfin"
    ]
    assert boundary.entered == boundary.released == 1
