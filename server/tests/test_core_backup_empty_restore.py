"""S09.2 empty-target restore and crash recovery contract."""

import os
from dataclasses import replace

import pytest
from conftest import auth, document, login, ready
from fastapi.testclient import TestClient
from larenor_server import cli
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.core_backups import restore as restore_module
from larenor_server.core_backups.restore import restore_empty
from larenor_server.errors import ApiError, StartupError
from larenor_server.files import private_create

PASSPHRASE = "Correct horse battery staple 2026"


def _bundle(server):
    app, client, settings, _clock = server
    pair = ready(server)
    stored = client.put(
        "/api/v1/vault",
        headers=auth(pair),
        json={"expectedRevision": 0, "document": document()},
    )
    assert stored.status_code == 200
    response = client.post(
        "/api/v1/admin/backups/export",
        headers=auth(pair),
        json={"passphrase": PASSPHRASE},
    )
    assert response.status_code == 200
    return response.content, settings.key_file.read_bytes(), app.state.core.context


def _target(tmp_path, clock):
    root = (tmp_path / "restored").resolve()
    return Settings(
        root / "data",
        root / "secrets/vault.key",
        clock=clock,
        login_ip_limit=100,
        login_account_limit=100,
        login_global_limit=100,
    )


def _assert_restored(settings, expected_key, expected_context):
    app = create_app(settings)
    assert not app.state.core.bootstrap_created
    assert settings.key_file.read_bytes() == expected_key
    assert app.state.core.context == expected_context
    with TestClient(app) as client:
        pair = login(client, "admin", "Synthetic new password 2026").json()
        response = client.get("/api/v1/vault", headers=auth(pair))
        assert response.status_code == 200
        assert response.json()["document"] == document()


def test_empty_restore_reopens_key_context_connection_and_vault_after_restart(
    server, tmp_path
):
    bundle, key, context = _bundle(server)
    target = _target(tmp_path, server[3])

    snapshot_id = restore_empty(target, bundle, PASSPHRASE)

    assert len(snapshot_id) == 32
    _assert_restored(target, key, context)
    _assert_restored(target, key, context)
    assert not list(target.data_dir.glob(".restore-*"))
    assert not (target.data_dir / ".restore-state.json").exists()


def test_empty_restore_preserves_family_board_snapshot_and_delta(server, tmp_path):
    app, client, _settings, clock = server
    pair = ready(server)
    context = app.state.core.context
    root = f"/api/v1/family-boards/{context.coreId}/{context.homeId}"
    authority = client.get(root + "/authority", headers=auth(pair)).json()
    board = root + "/" + authority["boardId"]
    card = {
        "schemaVersion": 1,
        "id": "8" * 32,
        "kind": "card",
        "text": "Movie night",
        "x": 24.0,
        "y": 24.0,
        "color": "yellow",
    }
    expectations = {
        "expectedHomeRevision": authority["homeRevision"],
        "expectedAccountRevision": authority["accountRevision"],
        "expectedMemberRevision": authority["memberRevision"],
        "expectedSessionFamilyId": authority["sessionFamilyId"],
    }
    response = client.post(
        board + "/commands",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": "9" * 32,
            "expectedBoardRevision": 0,
            "action": "append",
            "element": card,
            "elementId": None,
            **expectations,
        },
    )
    assert response.status_code == 200
    bundle = client.post(
        "/api/v1/admin/backups/export",
        headers=auth(pair),
        json={"passphrase": PASSPHRASE},
    )
    assert bundle.status_code == 200

    target = _target(tmp_path, clock)
    restore_empty(target, bundle.content, PASSPHRASE)
    restored = create_app(target)
    with TestClient(restored) as target_client:
        restored_pair = login(
            target_client, "admin", "Synthetic new password 2026"
        ).json()
        restored_authority = target_client.get(
            root + "/authority", headers=auth(restored_pair)
        ).json()
        assert restored_authority["boardId"] == authority["boardId"]
        snapshot = target_client.get(
            board, headers=auth(restored_pair)
        )
        assert snapshot.status_code == 200
        assert snapshot.json()["elements"] == [card]
        restored_expectations = {
            "expectedHomeRevision": restored_authority["homeRevision"],
            "expectedAccountRevision": restored_authority["accountRevision"],
            "expectedMemberRevision": restored_authority["memberRevision"],
            "expectedSessionFamilyId": restored_authority["sessionFamilyId"],
        }
        delta = target_client.post(
            board + "/delta",
            headers=auth(restored_pair),
            json={
                "schemaVersion": 1,
                "afterSequence": 0,
                "limit": 100,
                **restored_expectations,
            },
        )
        assert delta.status_code == 200
        assert len(delta.json()["events"]) == 1


@pytest.mark.parametrize("damage", ["wrong-password", "truncated", "tampered"])
def test_authentication_failures_leave_zero_partial_target(server, tmp_path, damage):
    bundle, _key, _context = _bundle(server)
    target = _target(tmp_path, server[3])
    passphrase = PASSPHRASE
    if damage == "wrong-password":
        passphrase = "Wrong horse battery staple 2026"
    elif damage == "truncated":
        bundle = bundle[:32]
    else:
        bundle = bundle[:-1] + bytes([bundle[-1] ^ 1])

    with pytest.raises(ApiError, match="backup_decryption_failed"):
        restore_empty(target, bundle, passphrase)

    assert not target.database_file.exists()
    assert not target.key_file.exists()
    assert not (target.data_dir / ".initialized").exists()
    assert not (target.data_dir / ".restore-state.json").exists()


def test_incompatible_bundle_is_rejected_before_staging(server, tmp_path, monkeypatch):
    bundle, _key, _context = _bundle(server)
    target = _target(tmp_path, server[3])
    capture = server[0].state.core.core_backups.open_bundle(bundle, PASSPHRASE)
    incompatible = replace(
        capture,
        manifest=capture.manifest.model_copy(update={"coreVersion": "99.0.0"}),
    )
    monkeypatch.setattr(restore_module, "open_backup_bundle", lambda *_: incompatible)

    with pytest.raises(ApiError, match="backup_incompatible"):
        restore_empty(target, bundle, PASSPHRASE)

    assert not target.database_file.exists()
    assert not target.key_file.exists()
    assert not list(target.data_dir.glob(".restore-*"))


def test_restart_finishes_interrupted_two_file_publication(server, tmp_path, monkeypatch):
    bundle, key, context = _bundle(server)
    target = _target(tmp_path, server[3])
    real_replace = os.replace
    calls = 0

    def interrupted(source, destination):
        nonlocal calls
        calls += 1
        # Journal promotion is the first replace; interrupt after publishing
        # the key, before publishing the database.
        if calls == 3:
            raise OSError("synthetic interruption")
        return real_replace(source, destination)

    with monkeypatch.context() as scoped:
        scoped.setattr(restore_module.os, "replace", interrupted)
        with pytest.raises(OSError, match="synthetic interruption"):
            restore_empty(target, bundle, PASSPHRASE)

    assert target.key_file.exists()
    assert not target.database_file.exists()
    assert (target.data_dir / ".restore-state.json").exists()

    _assert_restored(target, key, context)
    assert not (target.data_dir / ".restore-state.json").exists()


def test_journal_write_failure_discards_stage_and_allows_retry(
    server, tmp_path, monkeypatch
):
    bundle, key, context = _bundle(server)
    target = _target(tmp_path, server[3])
    real_create = restore_module.private_create

    def fail_journal(path, contents):
        if path.name == "restore-journal.json":
            raise OSError("synthetic journal write failure")
        return real_create(path, contents)

    with monkeypatch.context() as scoped:
        scoped.setattr(restore_module, "private_create", fail_journal)
        with pytest.raises(OSError, match="synthetic journal write failure"):
            restore_empty(target, bundle, PASSPHRASE)

    assert not target.database_file.exists()
    assert not target.key_file.exists()
    assert not list(target.data_dir.glob(".restore-*"))
    assert not list(target.key_file.parent.glob(".restore-*"))
    assert not (target.data_dir / ".restore-state.json").exists()
    restore_empty(target, bundle, PASSPHRASE)
    _assert_restored(target, key, context)


def test_failure_after_journal_promotion_recovers_on_restart(
    server, tmp_path, monkeypatch
):
    bundle, key, context = _bundle(server)
    target = _target(tmp_path, server[3])
    real_sync = restore_module.sync_directory

    def fail_after_promotion(path):
        if path == target.data_dir and (path / ".restore-state.json").exists():
            raise OSError("synthetic directory sync failure")
        return real_sync(path)

    with monkeypatch.context() as scoped:
        scoped.setattr(restore_module, "sync_directory", fail_after_promotion)
        with pytest.raises(OSError, match="synthetic directory sync failure"):
            restore_empty(target, bundle, PASSPHRASE)

    assert (target.data_dir / ".restore-state.json").exists()
    assert not target.database_file.exists()
    _assert_restored(target, key, context)
    assert not (target.data_dir / ".restore-state.json").exists()


def test_stage_cleanup_failure_keeps_journal_for_restart_recovery(
    server, tmp_path, monkeypatch
):
    bundle, key, context = _bundle(server)
    target = _target(tmp_path, server[3])
    real_cleanup = restore_module._cleanup_stage

    def fail_cleanup(stage_dir, stage_key):
        if target.database_file.exists():
            raise OSError("synthetic cleanup interruption")
        return real_cleanup(stage_dir, stage_key)

    with monkeypatch.context() as scoped:
        scoped.setattr(restore_module, "_cleanup_stage", fail_cleanup)
        with pytest.raises(OSError, match="synthetic cleanup interruption"):
            restore_empty(target, bundle, PASSPHRASE)

    assert target.database_file.exists()
    assert target.key_file.exists()
    assert (target.data_dir / ".restore-state.json").exists()
    _assert_restored(target, key, context)
    assert not (target.data_dir / ".restore-state.json").exists()
    assert not list(target.data_dir.glob(".restore-*"))


def test_restore_refuses_initialized_or_partially_owned_target(server, tmp_path):
    bundle, _key, _context = _bundle(server)
    target = _target(tmp_path, server[3])
    create_app(target)

    with pytest.raises(StartupError, match="restore_target_not_empty"):
        restore_empty(target, bundle, PASSPHRASE)

    unrelated = _target(tmp_path / "unrelated", server[3])
    unrelated.data_dir.mkdir(parents=True, mode=0o700)
    unrelated.data_dir.chmod(0o700)
    (unrelated.data_dir / "unknown-state").write_text("do not replace")
    with pytest.raises(StartupError, match="restore_target_not_empty"):
        restore_empty(unrelated, bundle, PASSPHRASE)
    assert (unrelated.data_dir / "unknown-state").read_text() == "do not replace"


def test_cli_reads_private_files_and_never_prints_passphrase(
    server, tmp_path, monkeypatch, capsys
):
    bundle, key, context = _bundle(server)
    target = _target(tmp_path, server[3])
    source = (tmp_path / "input").resolve()
    private_create(source / "backup.larenor-core", bundle)
    private_create(source / "passphrase", (PASSPHRASE + "\n").encode())
    monkeypatch.setattr(
        Settings,
        "from_environment",
        classmethod(lambda _cls: target),
    )

    result = cli.main(
        [
            "--restore",
            str(source / "backup.larenor-core"),
            "--restore-passphrase-file",
            str(source / "passphrase"),
        ]
    )

    output = capsys.readouterr()
    assert result == 0
    assert output.out == "Larenor Core restore completed.\n"
    assert output.err == ""
    assert PASSPHRASE not in output.out + output.err
    _assert_restored(target, key, context)
