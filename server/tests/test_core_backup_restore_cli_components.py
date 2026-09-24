"""Packaged offline CLI wiring for managed-component restore and restart."""

from contextlib import nullcontext

from larenor_server import cli
from larenor_server.core_backups.component_restore_runtime import (
    ComponentRestoreRuntimeConfig,
)
from larenor_server.files import private_create
from test_core_backup_empty_restore import PASSPHRASE, _target


def args(bundle, passphrase, root):
    return [
        "--restore",
        str(bundle),
        "--restore-passphrase-file",
        str(passphrase),
        "--component-restore-container-journal",
        str(root / "containers"),
        "--component-restore-volume-journal",
        str(root / "volumes"),
        "--component-restore-engine-socket",
        str(root / "engine.sock"),
        "--component-restore-recovery-journal",
        str(root / "component-recovery.json"),
        "--component-restore-recovery-key-file",
        str(root / "component-recovery.key"),
        "--component-restore-engine-uid",
        "0",
    ]


def test_cli_builds_root_only_runtime_and_reopens_core_after_one_decision(
    server, tmp_path, monkeypatch, capsys
):
    root = (tmp_path / "operator").resolve()
    root.mkdir(mode=0o700)
    bundle = root / "backup.larenor-core"
    passphrase = root / "passphrase"
    private_create(bundle, b"synthetic bounded bundle")
    private_create(passphrase, (PASSPHRASE + "\n").encode())
    target = _target(tmp_path / "target", server[3])
    runtime = object()
    observed = {}

    def build(config):
        observed["config"] = config
        return nullcontext(runtime)

    monkeypatch.setattr(cli.Settings, "from_environment", lambda: target)
    monkeypatch.setattr(
        cli,
        "build_component_restore_runtime",
        build,
    )
    monkeypatch.setattr(
        cli,
        "restore_empty",
        lambda *_args, **kwargs: observed.setdefault("restore", kwargs),
    )
    monkeypatch.setattr(
        cli,
        "create_configured_app",
        lambda settings: observed.setdefault("app", settings),
    )

    assert cli.main(args(bundle, passphrase, root)) == 0

    assert type(observed["config"]) is ComponentRestoreRuntimeConfig
    assert observed["config"].engine_uid == 0
    assert observed["restore"]["component_runtime"] is runtime
    assert type(observed["restore"]["deadline"]) is float
    assert observed["app"] is target
    output = capsys.readouterr()
    assert output.out == "Larenor Core restore completed.\n"
    assert output.err == ""


def test_cli_rejects_partial_component_authority_without_reading_secrets(
    tmp_path, monkeypatch
):
    root = (tmp_path / "operator").resolve()
    root.mkdir(mode=0o700)
    bundle = root / "missing-backup"
    passphrase = root / "missing-passphrase"
    monkeypatch.setattr(
        cli,
        "_read_restore_inputs",
        lambda *_args: (_ for _ in ()).throw(AssertionError("secret read")),
    )

    partial = args(bundle, passphrase, root)
    del partial[-4:]
    try:
        cli.main(partial)
    except SystemExit as error:
        assert error.code == 2
    else:
        raise AssertionError("partial component authority accepted")
