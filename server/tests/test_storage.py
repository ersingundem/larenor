from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import stat
import threading
import uuid

import pytest
from fastapi.testclient import TestClient

from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.errors import StartupError

from conftest import auth, bootstrap_password, document, login, ready


def test_bootstrap_restart_is_idempotent_and_all_material_is_private(server):
    app, client, settings, _ = server
    password = bootstrap_password(settings)
    with app.state.core.db.connection() as connection:
        before = tuple(connection.execute("SELECT id,password_hash FROM users").fetchone())
        assert connection.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
        assert connection.execute("PRAGMA synchronous").fetchone()[0] == 2
    restarted = create_app(settings)
    assert restarted.state.core.bootstrap_created is False
    assert bootstrap_password(settings) == password
    with restarted.state.core.db.connection() as connection:
        assert tuple(connection.execute("SELECT id,password_hash FROM users").fetchone()) == before
        assert connection.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 1
    for path in (settings.key_file, settings.database_file, settings.effective_bootstrap_file):
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert stat.S_IMODE(settings.data_dir.stat().st_mode) == 0o700
    assert stat.S_IMODE(settings.key_file.parent.stat().st_mode) == 0o700


def test_restart_after_password_change_never_recreates_default_credentials(server):
    app, _client, settings, _ = server
    pair = ready(server)
    recreated = create_app(settings)
    assert not settings.effective_bootstrap_file.exists()
    with TestClient(recreated) as client:
        response = client.get("/api/v1/auth/me", headers=auth(pair))
        assert response.status_code == 200
        assert response.json()["user"]["mustChangePassword"] is False


def test_missing_or_replaced_key_never_generates_a_replacement_for_existing_db(server):
    _app, _client, settings, _ = server
    original = settings.key_file.read_bytes()
    settings.key_file.unlink()
    with pytest.raises(StartupError, match="vault_key_missing"):
        create_app(settings)
    assert not settings.key_file.exists()
    settings.key_file.write_bytes(b"x" * 32)
    settings.key_file.chmod(0o600)
    with pytest.raises(StartupError, match="wrong_key"):
        create_app(settings)
    assert settings.key_file.read_bytes() == b"x" * 32
    settings.key_file.write_bytes(original)
    create_app(settings)


def test_missing_or_truncated_initialized_database_does_not_reset_admin(server):
    _app, _client, settings, _ = server
    ready(server)
    settings.database_file.write_bytes(b"")
    with pytest.raises(StartupError):
        create_app(settings)
    assert not settings.effective_bootstrap_file.exists()
    settings.database_file.unlink()
    with pytest.raises(StartupError, match="initialized_database_missing"):
        create_app(settings)
    assert not settings.database_file.exists()


def test_crash_after_db_publication_recovers_same_admin_and_bootstrap(tmp_path, monkeypatch):
    root = tmp_path.resolve()
    settings = Settings(root / "data", root / "secrets/vault.key")
    original = Path.unlink

    def interrupt(path, *args, **kwargs):
        if path.name.startswith(".initialize-") and path.name.endswith(".sqlite3"):
            raise SystemExit("simulated process interruption")
        return original(path, *args, **kwargs)

    with monkeypatch.context() as patch:
        patch.setattr(Path, "unlink", interrupt)
        with pytest.raises(SystemExit):
            create_app(settings)
    password = bootstrap_password(settings)
    assert settings.database_file.stat().st_nlink == 2
    app = create_app(settings)
    assert settings.database_file.stat().st_nlink == 1
    with TestClient(app) as client:
        assert login(client, "admin", password).status_code == 200
    assert app.state.core.bootstrap_created is False


def test_crash_before_db_publication_reuses_one_private_bootstrap_password(tmp_path, monkeypatch):
    root = tmp_path.resolve()
    settings = Settings(root / "data", root / "secrets/vault.key")
    with monkeypatch.context() as patch:
        patch.setattr(os, "link", lambda *_: (_ for _ in ()).throw(OSError("simulated disk failure")))
        with pytest.raises(StartupError):
            create_app(settings)
    assert not settings.database_file.exists()
    password = bootstrap_password(settings)
    app = create_app(settings)
    with TestClient(app) as client:
        assert login(client, "admin", password).status_code == 200
    assert app.state.core.bootstrap_created is False


def test_key_in_database_directory_and_symlink_paths_are_rejected(tmp_path):
    root = tmp_path.resolve()
    with pytest.raises(StartupError, match="outside_data_directory"):
        create_app(Settings(root / "data", root / "data/key"))
    other = root / "other"
    other.mkdir(mode=0o700)
    link = root / "link"
    link.symlink_to(other, target_is_directory=True)
    with pytest.raises(StartupError, match="symlink_storage_path"):
        create_app(Settings(link, root / "secrets/key"))
    assert list(other.iterdir()) == []


def test_non_private_existing_key_fails_without_chmod_or_rotation(server):
    _app, _client, settings, _ = server
    original = settings.key_file.read_bytes()
    settings.key_file.chmod(0o644)
    with pytest.raises(StartupError, match="storage_file_not_private"):
        create_app(settings)
    assert settings.key_file.read_bytes() == original
    assert stat.S_IMODE(settings.key_file.stat().st_mode) == 0o644


def test_vault_round_trip_is_encrypted_and_nonce_changes_for_each_revision(server):
    app, client, settings, _ = server
    pair = ready(server)
    assert client.get("/api/v1/vault", headers=auth(pair)).json() == {"revision": 0, "document": None}
    data = document()
    first = client.put("/api/v1/vault", headers=auth(pair), json={"expectedRevision": 0, "document": data})
    assert first.status_code == 200
    assert first.json() == {"revision": 1, "document": data}
    with app.state.core.db.connection() as connection:
        old = connection.execute("SELECT nonce,ciphertext FROM vaults").fetchone()
    second = client.put("/api/v1/vault", headers=auth(pair), json={"expectedRevision": 1, "document": data})
    assert second.status_code == 200
    with app.state.core.db.connection() as connection:
        new = connection.execute("SELECT nonce,ciphertext FROM vaults").fetchone()
    assert len(new["nonce"]) == 12
    assert old["nonce"] != new["nonce"]
    assert old["ciphertext"] != new["ciphertext"]
    assert b"synthetic-only-token" not in new["ciphertext"]
    assert b"synthetic-only-token" not in settings.database_file.read_bytes()
    assert client.get("/api/v1/vault", headers=auth(pair)).json() == {"revision": 2, "document": data}


def test_optimistic_revision_prevents_concurrent_lost_update(server):
    _app, client, _, _ = server
    pair = ready(server)
    barrier = threading.Barrier(2)

    def save(index):
        barrier.wait(timeout=5)
        return client.put("/api/v1/vault", headers=auth(pair), json={"expectedRevision": 0, "document": document(str(index))})

    with ThreadPoolExecutor(max_workers=2) as executor:
        responses = list(executor.map(save, range(2)))
    assert sorted(response.status_code for response in responses) == [200, 409]
    winner = next(response.json() for response in responses if response.status_code == 200)
    assert client.get("/api/v1/vault", headers=auth(pair)).json() == winner


def test_ciphertext_nonce_and_revision_tampering_fail_without_leaking_payload(server):
    app, client, _, _ = server
    pair = ready(server)
    client.put("/api/v1/vault", headers=auth(pair), json={"expectedRevision": 0, "document": document()})
    with app.state.core.db.transaction() as connection:
        connection.execute("UPDATE vaults SET revision=99")
    response = client.get("/api/v1/vault", headers=auth(pair))
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "vault_unavailable"
    assert "synthetic" not in response.text
    assert "traceback" not in response.text.lower()


def test_vault_is_user_scoped_and_cross_user_ciphertext_copy_fails_aad(server):
    app, client, _, _ = server
    admin = ready(server)
    core = app.state.core
    member_id = uuid.uuid4().hex
    with core.db.transaction() as connection:
        connection.execute("INSERT INTO users(id,username,role,password_hash,must_change_password,created_at) VALUES(?,?,?,?,?,?)",
                           (member_id, "member", "member", core.auth.hash_password("Synthetic member password"), 0, 1))
    member = login(client, "member", "Synthetic member password").json()
    client.put("/api/v1/vault", headers=auth(admin), json={"expectedRevision": 0, "document": document()})
    assert client.get("/api/v1/vault", headers=auth(member)).json() == {"revision": 0, "document": None}
    with core.db.transaction() as connection:
        connection.execute("INSERT INTO vaults SELECT ?,revision,nonce,ciphertext,updated_at FROM vaults WHERE user_id=?",
                           (member_id, admin["user"]["id"]))
    assert client.get("/api/v1/vault", headers=auth(member)).status_code == 503
    assert client.get("/api/v1/vault", headers=auth(admin)).status_code == 200


@pytest.mark.parametrize("mutation", [
    lambda item: item.update(version=2),
    lambda item: item.update(extra="not allowed"),
    lambda item: item["snapshot"].update(version=1),
    lambda item: item["snapshot"].update(createdAt="invalid date"),
    lambda item: item["snapshot"]["groups"].pop("privacy"),
    lambda item: item["snapshot"]["groups"].update(wellbeing={"privateMeasurements": [1]}),
    lambda item: item["snapshot"]["groups"]["privacy"].update(version=True),
    lambda item: item["snapshot"]["groups"]["privacy"].update(entityIds=["light.private"]),
    lambda item: item["snapshot"]["groups"]["privacy"].update(entityIds=["sensor.a", "sensor.a"]),
    lambda item: item["snapshot"]["groups"]["privacy"].update(reviewRequired="false"),
])
def test_vault_envelope_privacy_and_version_validation(server, mutation):
    app, client, _, _ = server
    pair = ready(server)
    data = document()
    mutation(data)
    response = client.put("/api/v1/vault", headers=auth(pair), json={"expectedRevision": 0, "document": data})
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_request"
    with app.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM vaults").fetchone()[0] == 0
