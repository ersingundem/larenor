"""Offline, privileged composition for production component restores."""

import os
from pathlib import Path

import pytest
from larenor_server.core_backups.component_restore import ComponentRestorePlanError
from larenor_server.core_backups.component_restore_runtime import (
    ComponentRestoreRuntimeConfig,
    ComponentRestoreRuntimeError,
    build_component_restore_runtime,
)
from larenor_server.plugins.managed_container import ManagedWorkerJournal
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal


class RestoreSystem:
    def exchange_between(self, *_args):
        raise AssertionError("not dispatched during composition")

    def move(self, *_args):
        raise AssertionError("not dispatched during composition")


def initialized_journals(tmp_path):
    containers = tmp_path / "containers"
    volumes = tmp_path / "volumes"
    with (
        ManagedWorkerJournal(containers, initialize=True),
        VolumeCreateJournal(volumes, initialize=True),
    ):
        pass
    return containers, volumes


def selected_config(tmp_path):
    root = tmp_path.resolve()
    containers, volumes = initialized_journals(root)
    key = root / "restore.key"
    key.write_bytes(b"k" * 32)
    key.chmod(0o600)
    return ComponentRestoreRuntimeConfig(
        container_journal=containers,
        volume_journal=volumes,
        engine_socket=Path("/tmp") / f"engine-{os.getpid()}-{tmp_path.name}.sock",
        recovery_journal=root / "restore-recovery.json",
        recovery_key_file=key,
        engine_uid=os.getuid(),
    )


@pytest.mark.parametrize(
    "change",
    (
        {"container_journal": Path("relative")},
        {"engine_socket": Path("/")},
        {"engine_uid": True},
        {"engine_uid": -1},
    ),
)
def test_config_rejects_ambiguous_or_unbounded_authority_paths(tmp_path, change):
    values = vars(selected_config(tmp_path)).copy()
    values.update(change)
    with pytest.raises(
        ComponentRestoreRuntimeError, match="component_restore_unavailable"
    ):
        ComponentRestoreRuntimeConfig(**values)


def test_config_rejects_duplicate_authority_or_recovery_paths(tmp_path):
    selected = selected_config(tmp_path)
    values = vars(selected).copy()
    values["recovery_journal"] = selected.container_journal
    with pytest.raises(
        ComponentRestoreRuntimeError, match="component_restore_unavailable"
    ):
        ComponentRestoreRuntimeConfig(**values)


def test_runtime_is_root_only_before_opening_operator_files(tmp_path, monkeypatch):
    selected = selected_config(tmp_path)
    selected.recovery_key_file.unlink()
    monkeypatch.setattr(os, "geteuid", lambda: 10001)

    with pytest.raises(
        ComponentRestoreRuntimeError, match="component_restore_unavailable"
    ):
        build_component_restore_runtime(selected)


def test_runtime_composes_exact_durable_authority_without_engine_effects(tmp_path):
    selected = selected_config(tmp_path)
    with build_component_restore_runtime(
        selected,
        require_privileged=False,
        docker_peer_uid=lambda _connection: os.getuid(),
        system=RestoreSystem(),
    ) as runtime:
        assert runtime.journal.exists() is False
        assert runtime.config == selected
        assert "private" in repr(runtime)
        with pytest.raises(ComponentRestorePlanError):
            runtime.recover(object(), deadline=1.0)


def test_runtime_rejects_non_exact_configuration_type():
    with pytest.raises(
        ComponentRestoreRuntimeError, match="component_restore_unavailable"
    ):
        build_component_restore_runtime(object(), require_privileged=False)
