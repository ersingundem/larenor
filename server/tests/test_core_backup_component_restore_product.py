"""One durable publication decision for Core and managed component state."""

import json
import time

import pytest
from conftest import auth, ready

from larenor_server.core_backups import restore as restore_module
from larenor_server.errors import StartupError
from test_core_backup_components import PASSPHRASE, _install_boundary
from test_core_backup_empty_restore import _assert_restored, _target


class RuntimeJournal:
    def __init__(self):
        self.present = False

    def exists(self):
        return self.present


class ComponentRuntime:
    def __init__(self, settings, *, fail_before_release=False):
        self.settings = settings
        self.fail_before_release = fail_before_release
        self.journal = RuntimeJournal()
        self.events = []

    def restore(self, capture, *, deadline, checkpoint=None):
        assert time.monotonic() < deadline
        assert not self.settings.database_file.exists()
        assert checkpoint is not None
        self.events.append(("restore", capture.manifest.snapshotId))
        self.journal.present = True
        if self.fail_before_release:
            raise RuntimeError("synthetic private provider failure")
        checkpoint({"phase": "released"})
        self.journal.present = False
        return object()

    def recover(self, capture, *, deadline, checkpoint=None):
        assert time.monotonic() < deadline
        self.events.append(("recover", capture.manifest.snapshotId))
        checkpoint({"phase": "released"})
        self.journal.present = False
        return True


def component_bundle(server, monkeypatch):
    app, client, settings, _clock = server
    _install_boundary(server, monkeypatch)
    pair = ready(server)
    response = client.post(
        "/api/v1/admin/backups/export",
        headers=auth(pair),
        json={"passphrase": PASSPHRASE},
    )
    assert response.status_code == 200
    return response.content, settings.key_file.read_bytes(), app.state.core.context


def test_core_publication_waits_for_component_release(server, tmp_path, monkeypatch):
    bundle, key, context = component_bundle(server, monkeypatch)
    target = _target(tmp_path, server[3])
    runtime = ComponentRuntime(target)

    snapshot_id = restore_module.restore_empty(
        target,
        bundle,
        PASSPHRASE,
        component_runtime=runtime,
        deadline=time.monotonic() + 5,
    )

    assert runtime.events == [("restore", snapshot_id)]
    _assert_restored(target, key, context)
    assert not (target.data_dir / ".restore-state.json").exists()


def test_pending_core_decision_cannot_publish_and_exact_retry_recovers(
    server, tmp_path, monkeypatch
):
    bundle, key, context = component_bundle(server, monkeypatch)
    target = _target(tmp_path, server[3])
    failed = ComponentRuntime(target, fail_before_release=True)

    with pytest.raises(RuntimeError, match="synthetic private provider failure"):
        restore_module.restore_empty(
            target,
            bundle,
            PASSPHRASE,
            component_runtime=failed,
            deadline=time.monotonic() + 5,
        )
    with pytest.raises(StartupError, match="restore_components_pending"):
        restore_module.recover_empty_restore(target)
    journal = json.loads((target.data_dir / ".restore-state.json").read_text())
    assert journal["componentState"] == "pending"
    assert not target.database_file.exists()

    recovered = ComponentRuntime(target)
    recovered.journal.present = True
    snapshot_id = restore_module.restore_empty(
        target,
        bundle,
        PASSPHRASE,
        component_runtime=recovered,
        deadline=time.monotonic() + 5,
    )

    assert recovered.events == [("recover", snapshot_id)]
    _assert_restored(target, key, context)

