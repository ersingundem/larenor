"""Shared export/restore passphrase boundaries for the offline CLI."""

import pytest
from conftest import auth, document, ready
from test_core_backup_empty_restore import _assert_restored, _target

from larenor_server import cli
from larenor_server.config import Settings
from larenor_server.files import private_create


def _bundle(server, passphrase):
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
        json={"passphrase": passphrase},
    )
    assert response.status_code == 200
    return response.content, settings.key_file.read_bytes(), app.state.core.context


def _run_restore(monkeypatch, target, bundle_path, passphrase_path):
    monkeypatch.setattr(
        Settings,
        "from_environment",
        classmethod(lambda _cls: target),
    )
    return cli.main(
        [
            "--restore",
            str(bundle_path),
            "--restore-passphrase-file",
            str(passphrase_path),
        ]
    )


def test_cli_restores_export_with_128_multibyte_character_passphrase(
    server, tmp_path, monkeypatch, capsys
):
    passphrase = "🙂" * 128
    bundle, key, context = _bundle(server, passphrase)
    source = (tmp_path / "input").resolve()
    bundle_path = source / "backup.larenor-core"
    passphrase_path = source / "passphrase"
    private_create(bundle_path, bundle)
    private_create(passphrase_path, (passphrase + "\n").encode("utf-8"))
    target = _target(tmp_path, server[3])

    result = _run_restore(
        monkeypatch,
        target,
        bundle_path,
        passphrase_path,
    )

    output = capsys.readouterr()
    assert result == 0
    assert output.out == "Larenor Core restore completed.\n"
    assert output.err == ""
    assert passphrase not in output.out + output.err
    _assert_restored(target, key, context)


@pytest.mark.parametrize(
    "invalid",
    (
        "too short",
        "Synthetic restore\x7fpassphrase 2026",
        "x" * 129,
    ),
)
def test_cli_rejects_invalid_passphrase_before_restore_without_echo(
    server, tmp_path, monkeypatch, capsys, invalid
):
    bundle, _key, _context = _bundle(
        server,
        "Correct horse battery staple 2026",
    )
    source = (tmp_path / invalid[:4].encode().hex()).resolve()
    bundle_path = source / "backup.larenor-core"
    passphrase_path = source / "passphrase"
    private_create(bundle_path, bundle)
    private_create(passphrase_path, (invalid + "\n").encode("utf-8"))
    target = _target(tmp_path / "target", server[3])

    result = _run_restore(
        monkeypatch,
        target,
        bundle_path,
        passphrase_path,
    )

    output = capsys.readouterr()
    assert result == 1
    assert output.out == ""
    assert output.err == (
        "Larenor Server initialization failed: restore_passphrase_invalid\n"
    )
    assert invalid not in output.err
    assert not target.database_file.exists()
    assert not target.key_file.exists()
