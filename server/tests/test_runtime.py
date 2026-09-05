import stat

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.config import Settings
from larenor_server.errors import StartupError
from larenor_server.runtime import create_configured_app


def test_normal_entrypoint_registers_authenticated_release_and_admin_routes(tmp_path):
    settings = Settings(tmp_path.resolve() / "data", tmp_path.resolve() / "secrets/vault.key")
    app = create_configured_app(settings)
    with TestClient(app) as client:
        assert client.get("/api/v1/client/releases/latest").status_code == 401
        pair = ready((app, client, settings, None))
        assert client.get("/api/v1/client/releases/latest", headers=auth(pair)).status_code == 204
        assert client.get("/api/v1/admin/users", headers=auth(pair)).status_code == 200
        schema = client.get("/api/v1/openapi.json", headers=auth(pair)).json()
        assert "/api/v1/client/releases/latest" in schema["paths"]
        assert "/api/v1/admin/users" in schema["paths"]
        upload = schema["paths"]["/api/v1/client/releases/{version_code}/uploads/{upload_id}/apk"]["put"]
        assert upload["requestBody"]["content"]["application/octet-stream"]["schema"]["format"] == "binary"
        assert upload["security"] == [{"ReleasePublishToken": []}]
        manifest = schema["paths"]["/api/v1/client/releases/{version_code}"]["put"]["requestBody"]["content"]["application/json"]["schema"]
        assert manifest["properties"]["sizeBytes"]["maximum"] == 512 * 1024 * 1024
        assert len(manifest["required"]) == 12
    token_file = app.state.publisher_credential_file
    assert stat.S_IMODE(token_file.stat().st_mode) == 0o600
    original = token_file.read_bytes()
    assert original.startswith(b"lpub_") and len(original) == 49
    again = create_configured_app(settings)
    assert not again.state.publisher_credential_created
    assert token_file.read_bytes() == original
    assert not app.state.releases.settings.publisher_token


def test_existing_invalid_publisher_file_fails_without_replacing_it(tmp_path):
    settings = Settings(tmp_path.resolve() / "data", tmp_path.resolve() / "secrets/vault.key")
    app = create_configured_app(settings)
    file = app.state.publisher_credential_file
    file.write_bytes(b"synthetic-invalid")
    with pytest.raises(StartupError, match="publisher_credential_invalid"):
        create_configured_app(settings)
    assert file.read_bytes() == b"synthetic-invalid"


def test_invalid_certificate_pin_is_rejected_at_startup(tmp_path, monkeypatch):
    monkeypatch.setenv("LARENOR_CLIENT_SIGNER_SHA256", "invalid")
    settings = Settings(tmp_path.resolve() / "data", tmp_path.resolve() / "secrets/vault.key")
    with pytest.raises(StartupError, match="invalid_release_settings"):
        create_configured_app(settings)


def test_relative_publisher_path_rejected_before_core_initialization(tmp_path, monkeypatch):
    monkeypatch.setenv("LARENOR_PUBLISHER_TOKEN_FILE", "publisher.token")
    settings = Settings(tmp_path.resolve() / "data", tmp_path.resolve() / "secrets/vault.key")
    with pytest.raises(StartupError, match="publisher_path_invalid"):
        create_configured_app(settings)
    assert not settings.data_dir.exists()


def test_publisher_credential_cannot_be_placed_inside_database_backups(tmp_path, monkeypatch):
    settings = Settings(tmp_path.resolve() / "data", tmp_path.resolve() / "secrets/vault.key")
    monkeypatch.setenv("LARENOR_PUBLISHER_TOKEN_FILE", str(settings.data_dir / "publisher.token"))
    with pytest.raises(StartupError, match="publisher_credential_must_be_outside_data_directory"):
        create_configured_app(settings)
    assert not settings.data_dir.exists()
