"""Packaged offline CLI wiring for managed-component restore and restart."""

from contextlib import nullcontext
import os
import sys

import pytest

from larenor_server import cli
from larenor_server.core_backups.component_restore_runtime import (
    ComponentRestoreRuntimeConfig,
    ComponentRestoreRuntimeError,
)
from larenor_server.files import private_create
from test_core_backup_empty_restore import PASSPHRASE, _target
from test_core_backup_empty_restore import _encrypted_bundle


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


def test_cli_proves_privileged_runtime_before_reading_restore_secrets(
    server, tmp_path, monkeypatch, capsys
):
    root = (tmp_path / "operator").resolve()
    root.mkdir(mode=0o700)
    target = _target(tmp_path / "target", server[3])
    monkeypatch.setattr(cli.Settings, "from_environment", lambda: target)
    monkeypatch.setattr(
        cli,
        "build_component_restore_runtime",
        lambda _config: (_ for _ in ()).throw(ComponentRestoreRuntimeError()),
    )
    monkeypatch.setattr(
        cli,
        "_read_restore_inputs",
        lambda *_args: (_ for _ in ()).throw(AssertionError("secret read")),
    )

    assert cli.main(args(root / "missing", root / "missing-secret", root)) == 1
    output = capsys.readouterr()
    assert output.out == ""
    assert output.err == (
        "Larenor Server initialization failed: component_restore_unavailable\n"
    )


@pytest.mark.skipif(
    sys.platform != "linux" or os.geteuid() != 0,
    reason="requires root Linux restore authority",
)
def test_native_root_cli_restores_core_and_components_then_reopens(
    server, tmp_path, monkeypatch
):
    from larenor_server.app import create_app
    from test_core_backup_component_linux_restore import (
        _close_production_inputs,
        _production_inputs,
    )

    inputs = _production_inputs(server, tmp_path / "native")
    try:
        operator = (tmp_path / "operator").resolve()
        operator.mkdir(mode=0o700)
        bundle = operator / "backup.larenor-core"
        passphrase = operator / "passphrase"
        recovery_key = operator / "component-recovery.key"
        private_create(bundle, _encrypted_bundle(inputs["opened"]))
        private_create(passphrase, (PASSPHRASE + "\n").encode())
        private_create(recovery_key, b"r" * 32)
        target = _target(tmp_path / "target", server[3])
        monkeypatch.setattr(cli.Settings, "from_environment", lambda: target)
        native_args = args(bundle, passphrase, operator)
        positions = {
            value: index for index, value in enumerate(native_args) if value.startswith("--")
        }
        native_args[positions["--component-restore-container-journal"] + 1] = str(
            inputs["authority"]._containers.directory
        )
        native_args[positions["--component-restore-volume-journal"] + 1] = str(
            inputs["authority"]._volumes.directory
        )
        native_args[positions["--component-restore-engine-socket"] + 1] = (
            inputs["endpoint"].path
        )
        native_args[positions["--component-restore-recovery-key-file"] + 1] = str(
            recovery_key
        )
        native_args[positions["--component-restore-engine-uid"] + 1] = str(
            inputs["endpoint"].owner_uid
        )

        assert cli.main(native_args) == 0
        app = create_app(target)
        assert app.state.core.context == server[0].state.core.context
        assert inputs["state"]["paused"] is False
        assert inputs["journal"].exists() is False
        for volume in inputs["receipt"].volumes:
            root = inputs["roots"][volume.intent.binding.resource.name]
            assert (root / "current.txt").read_text(encoding="utf-8") == "new"
    finally:
        _close_production_inputs(inputs)
