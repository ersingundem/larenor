"""Root Linux end-to-end journey through the packaged restore CLI."""

import os
import sys

import pytest
from larenor_server import cli
from larenor_server.app import create_app
from larenor_server.files import private_create
from test_core_backup_component_linux_restore import (
    _close_production_inputs,
    _production_inputs,
)
from test_core_backup_empty_restore import PASSPHRASE, _encrypted_bundle, _target
from test_core_backup_restore_cli_components import args


@pytest.mark.skipif(
    sys.platform != "linux" or os.geteuid() != 0,
    reason="requires root Linux restore authority",
)
def test_native_root_cli_restores_core_and_components_then_reopens(
    server, tmp_path, monkeypatch
):
    inputs = _production_inputs(server, tmp_path)
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
            value: index
            for index, value in enumerate(native_args)
            if value.startswith("--")
        }
        native_args[positions["--component-restore-container-journal"] + 1] = str(
            inputs["authority"]._containers.directory
        )
        native_args[positions["--component-restore-volume-journal"] + 1] = str(
            inputs["authority"]._volumes.directory
        )
        native_args[positions["--component-restore-engine-socket"] + 1] = inputs[
            "endpoint"
        ].path
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
        assert (operator / "component-recovery.json").exists() is False
        for volume in inputs["receipt"].volumes:
            root = inputs["roots"][volume.intent.binding.resource.name]
            assert (root / "current.txt").read_text(encoding="utf-8") == "new"
    finally:
        _close_production_inputs(inputs)
