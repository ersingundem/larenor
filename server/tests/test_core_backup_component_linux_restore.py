"""S09.2 Linux restore authority and descriptor-bound publication."""

import importlib
import importlib.util
import io
import os
import stat
import time
import zipfile

import pytest

from larenor_server.core_backups.component_restore import (
    ComponentRestorePlanError,
    ComponentRestoreVolumeTarget,
    plan_component_restore,
)
from larenor_server.core_backups.component_snapshot_provider import (
    ComponentVolumeSource,
    archive_component_directory,
)
from test_core_backup_component_docker_adapter import installed_authority
from test_core_backup_component_restore import capture


def api():
    name = "larenor_server.core_backups.component_linux_restore"
    assert importlib.util.find_spec(name) is not None, (
        "Linux component restore adapter is absent"
    )
    return importlib.import_module(name)


def test_durable_receipts_map_to_secret_free_exact_restore_authority(server, tmp_path):
    with installed_authority(tmp_path) as (authority, receipt, _binding, _volumes):
        restore_authority = api().DurableComponentRestoreAuthority(authority)
        targets = restore_authority.snapshot()
        plan = plan_component_restore(capture(server), restore_authority)

    assert len(targets) == 1
    target = targets[0]
    assert target.service_id == receipt.service_id
    assert target.installation_id == receipt.installation_id
    assert target.installation_revision > 0
    assert tuple(item.volume_id for item in target.volumes) == tuple(
        item.volume_id for item in receipt.volumes
    )
    assert all(len(item.binding_id) == 64 for item in target.volumes)
    assert tuple(item.binding_revision for item in target.volumes) == tuple(
        item.intent.receipt.revision for item in receipt.volumes
    )
    assert plan.targets[0].installation_revision == target.installation_revision
    assert repr(target) == "ComponentRestoreAuthorityTarget(<private>)"


def test_authority_rejects_receipt_drift_without_publishing_foreign_target(
    server, tmp_path
):
    with installed_authority(tmp_path) as (authority, _receipt, _binding, volumes):
        restore_authority = api().DurableComponentRestoreAuthority(authority)
        opened = capture(server)
        restore_authority.snapshot()
        volumes._db.execute(
            "UPDATE resources SET revision=revision+1 WHERE resource_id="
            "(SELECT resource_id FROM resources ORDER BY resource_id LIMIT 1)"
        )

        with pytest.raises(
            ComponentRestorePlanError,
            match="^component_restore_unavailable$",
        ):
            plan_component_restore(opened, restore_authority)


class PortableExchange:
    """Test-only exchange seam; production uses Linux renameat2."""

    @staticmethod
    def exchange(parent, first, second):
        temporary = ".larenor-test-exchange"
        os.rename(first, temporary, src_dir_fd=parent, dst_dir_fd=parent)
        os.rename(second, first, src_dir_fd=parent, dst_dir_fd=parent)
        os.rename(temporary, second, src_dir_fd=parent, dst_dir_fd=parent)


def _payload(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        return archive_component_directory(descriptor, time.monotonic() + 2)
    finally:
        os.close(descriptor)


def _engine_pair(tmp_path):
    target_path = tmp_path / "music-assistant-data"
    target_path.mkdir(mode=0o700)
    (target_path / "current.txt").write_text("old", encoding="utf-8")
    os.chmod(target_path / "current.txt", 0o600)
    info = target_path.stat()
    source = ComponentVolumeSource(
        service_id="music_assistant",
        container_id="a" * 64,
        volume_id="music-assistant-data",
        path=target_path,
        service_version="2.4.0",
        config_schema_version=1,
        data_schema_version="1",
        installation_revision=7,
        device=info.st_dev,
        inode=info.st_ino,
    )
    replacement = tmp_path / "replacement"
    replacement.mkdir(mode=0o700)
    (replacement / "current.txt").write_text("new", encoding="utf-8")
    os.chmod(replacement / "current.txt", 0o600)
    payload = _payload(replacement)
    target = ComponentRestoreVolumeTarget(
        resource_id="component-music-assistant-data",
        volume_id="music-assistant-data",
        binding_id="b" * 64,
        binding_revision=7,
        byte_length=len(payload),
        sha256=__import__("hashlib").sha256(payload).hexdigest(),
    )
    return source, target, payload, target_path


def test_linux_engine_stages_commits_and_rolls_back_descriptor_bound_tree(tmp_path):
    source, target, payload, target_path = _engine_pair(tmp_path)
    engine = api().LinuxDirectoryRestoreEngine(system=PortableExchange())
    deadline = time.monotonic() + 3
    leases = engine.acquire(((source, target),), "c" * 32, deadline)
    lease = leases[0]
    try:
        engine.capture_rollback(lease, deadline)
        engine.stage(lease, payload, deadline)
        assert engine.revalidate(leases, deadline) is True

        assert engine.commit(lease, deadline) is True
        assert (target_path / "current.txt").read_text(encoding="utf-8") == "new"
        assert engine.rollback(lease, deadline) is True
        assert (target_path / "current.txt").read_text(encoding="utf-8") == "old"
        assert not (tmp_path / lease.stage_name).exists()
    finally:
        engine.close(leases)


def test_linux_engine_rejects_same_content_path_replacement(tmp_path):
    source, target, payload, target_path = _engine_pair(tmp_path)
    engine = api().LinuxDirectoryRestoreEngine(system=PortableExchange())
    deadline = time.monotonic() + 3
    leases = engine.acquire(((source, target),), "d" * 32, deadline)
    lease = leases[0]
    try:
        engine.capture_rollback(lease, deadline)
        engine.stage(lease, payload, deadline)
        displaced = tmp_path / "displaced"
        target_path.rename(displaced)
        target_path.mkdir(mode=0o700)
        (target_path / "current.txt").write_text("old", encoding="utf-8")
        os.chmod(target_path / "current.txt", 0o600)

        assert engine.revalidate(leases, deadline) is False
        with pytest.raises(ComponentRestorePlanError):
            engine.commit(lease, deadline)
    finally:
        engine.close(leases)


def test_linux_engine_rejects_traversal_and_removes_partial_stage(tmp_path):
    source, target, _payload_bytes, _target_path = _engine_pair(tmp_path)
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        entry = zipfile.ZipInfo("../escape")
        entry.create_system = 3
        entry.compress_type = zipfile.ZIP_DEFLATED
        entry.external_attr = (stat.S_IFREG | 0o600) << 16
        archive.writestr(entry, b"escape")
    payload = output.getvalue()
    malformed = ComponentRestoreVolumeTarget(
        resource_id=target.resource_id,
        volume_id=target.volume_id,
        binding_id=target.binding_id,
        binding_revision=target.binding_revision,
        byte_length=len(payload),
        sha256=__import__("hashlib").sha256(payload).hexdigest(),
    )
    engine = api().LinuxDirectoryRestoreEngine(system=PortableExchange())
    deadline = time.monotonic() + 3
    leases = engine.acquire(((source, malformed),), "e" * 32, deadline)
    lease = leases[0]
    try:
        engine.capture_rollback(lease, deadline)
        with pytest.raises(ComponentRestorePlanError):
            engine.stage(lease, payload, deadline)
        assert not (tmp_path / "escape").exists()
        assert not (tmp_path / lease.stage_name).exists()
    finally:
        engine.close(leases)
