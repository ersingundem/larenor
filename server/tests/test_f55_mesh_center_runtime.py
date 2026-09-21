from fastapi.testclient import TestClient
from larenor_server.app import create_app
from larenor_server.config import Settings


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
