import os
import stat
import tempfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.config import Settings
from larenor_server.errors import StartupError
from larenor_server.media_archive_actions.worker_ipc import (
    MediaArchiveActionWorkerClient,
)
from larenor_server.plugins.media_archive_worker_ipc import (
    MediaArchiveWorkerClient, MediaArchiveWorkerError,
)
from larenor_server.plugins.media_archive_provider import (
    MediaArchiveWorkerProvider,
)
from larenor_server.runtime import create_configured_app
from test_media_archive_core_read import authority as archive_authority


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
    assert app.state.beta_releases.source.repository == "ersingundem/larenor"
    assert app.state.beta_releases.poll_seconds == 900


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


@pytest.mark.parametrize(("name", "value"), [
    ("LARENOR_BETA_SOURCE_REPOSITORY", "private-owner/private-repository"),
    ("LARENOR_BETA_POLL_SECONDS", "59"),
    ("LARENOR_BETA_POLL_SECONDS", "not-a-number"),
    ("LARENOR_BETA_MAX_AGE_SECONDS", "3599"),
])
def test_beta_source_configuration_is_all_or_nothing_and_secret_free(tmp_path, monkeypatch, name, value):
    monkeypatch.setenv(name, value)
    settings = Settings(tmp_path.resolve() / "data", tmp_path.resolve() / "secrets/vault.key")
    with pytest.raises(StartupError, match="^invalid_beta_source_settings$") as error:
        create_configured_app(settings)
    assert value not in str(error.value)
    assert not settings.data_dir.exists()


def test_configured_app_wires_opted_in_media_archive_workers(tmp_path):
    root = tmp_path.resolve()
    read_socket = root / "media-archive-read.sock"
    action_socket = root / "media-archive-action.sock"
    authority_socket = root / "media-archive-authority.sock"
    settings = Settings(
        root / "data",
        root / "secrets/vault.key",
        media_archive_worker_socket=read_socket,
        media_archive_worker_uid=os.getuid(),
        media_archive_action_worker_socket=action_socket,
        media_archive_action_worker_uid=os.getuid(),
        media_archive_authority_socket=authority_socket,
    )

    app = create_configured_app(settings)

    health = app.state.core.media_archive_health
    assert isinstance(health.binding_reader, MediaArchiveWorkerProvider)
    assert health.backend is health.binding_reader
    assert isinstance(health.backend.backend, MediaArchiveWorkerClient)
    assert health.backend.backend.path == read_socket
    assert health.backend.backend.owner_uid == os.getuid()
    actions = app.state.core.media_archive_actions.backend
    assert isinstance(actions, MediaArchiveActionWorkerClient)
    assert actions.path == action_socket
    assert actions.owner_uid == actions.peer_uid == os.getuid()
    assert app.state.core.media_archive_provider is health.backend


def test_core_lifespan_serves_only_live_archive_authority(tmp_path):
    root = tmp_path.resolve()
    with tempfile.TemporaryDirectory(prefix="la-", dir="/tmp") as socket_dir:
        authority_socket = Path(socket_dir) / "authority.sock"
        settings = Settings(
            root / "data", root / "secrets/vault.key",
            media_archive_worker_socket=root / "read.sock",
            media_archive_worker_uid=os.getuid(),
            media_archive_action_worker_socket=root / "action.sock",
            media_archive_action_worker_uid=os.getuid(),
            media_archive_authority_socket=authority_socket,
        )
        app = create_configured_app(settings)
        current = [archive_authority(), archive_authority(snapshot=5)]
        provider = app.state.core.media_archive_provider
        provider.current = lambda installation_id: (
            current[0] if installation_id == current[0].installationId
            else (_ for _ in ()).throw(ValueError("unknown installation"))
        )
        with TestClient(app):
            assert app.state.media_archive_authority_server is not None
            assert settings.media_archive_authority_socket.is_socket()
            reader = MediaArchiveWorkerClient(
                settings.media_archive_authority_socket,
                owner_uid=os.getuid())
            assert reader.status() == {
                "state": "unavailable",
                "authorityAvailable": True,
                "readAvailable": False,
                "mutationAvailable": False,
            }
            assert reader.current(current[0].installationId) == current[0]
            current.pop(0)
            assert reader.current(current[0].installationId) == current[0]
            with pytest.raises(MediaArchiveWorkerError):
                reader.current("f" * 32)
        assert not settings.media_archive_authority_socket.exists()


def test_core_authority_startup_failure_closes_clients_before_dispatch(tmp_path):
    root = tmp_path.resolve()
    settings = Settings(
        root / "data", root / "secrets/vault.key",
        media_archive_worker_socket=root / "read.sock",
        media_archive_worker_uid=os.getuid(),
        media_archive_action_worker_socket=root / "action.sock",
        media_archive_action_worker_uid=os.getuid(),
        media_archive_authority_socket=root / "missing/authority.sock",
    )
    app = create_configured_app(settings)
    closed = []
    for name in (
        "home_assistant", "proxmox", "keenetic_resources",
        "direct_ha_migration", "proxmox_power",
    ):
        setattr(
            getattr(app.state.core, name), "close",
            lambda name=name: closed.append(name),
        )

    with pytest.raises(StartupError, match="^invalid_worker_configuration$"):
        with TestClient(app):
            pytest.fail("lifespan startup must fail closed")

    assert set(closed) == {
        "home_assistant", "proxmox", "keenetic_resources",
        "direct_ha_migration", "proxmox_power",
    }
    assert app.state.plugin_job_dispatcher is None
    assert getattr(app.state, "media_archive_action_dispatcher", None) is None


def test_media_archive_worker_environment_is_exact_and_fail_closed(
    tmp_path, monkeypatch,
):
    root = tmp_path.resolve()
    read_socket = root / "media-archive-read.sock"
    action_socket = root / "media-archive-action.sock"
    authority_socket = root / "media-archive-authority.sock"
    monkeypatch.setenv("LARENOR_DATA_DIR", str(root / "data"))
    monkeypatch.setenv("LARENOR_KEY_FILE", str(root / "secrets/vault.key"))
    monkeypatch.setenv("LARENOR_MEDIA_ARCHIVE_WORKER_SOCKET", str(read_socket))
    monkeypatch.setenv("LARENOR_MEDIA_ARCHIVE_WORKER_UID", str(os.getuid()))
    monkeypatch.setenv(
        "LARENOR_MEDIA_ARCHIVE_ACTION_WORKER_SOCKET", str(action_socket)
    )
    monkeypatch.setenv(
        "LARENOR_MEDIA_ARCHIVE_ACTION_WORKER_UID", str(os.getuid())
    )
    monkeypatch.setenv(
        "LARENOR_MEDIA_ARCHIVE_AUTHORITY_SOCKET", str(authority_socket)
    )

    settings = Settings.from_environment()

    assert settings.media_archive_worker_socket == read_socket
    assert settings.media_archive_worker_uid == os.getuid()
    assert settings.media_archive_action_worker_socket == action_socket
    assert settings.media_archive_action_worker_uid == os.getuid()
    assert settings.media_archive_authority_socket == authority_socket

    monkeypatch.delenv("LARENOR_MEDIA_ARCHIVE_WORKER_SOCKET")
    with pytest.raises(StartupError, match="^invalid_worker_configuration$"):
        Settings.from_environment()
