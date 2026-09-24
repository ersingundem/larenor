"""S09.2 Linux restore authority and descriptor-bound publication."""

import importlib
import importlib.util
import io
import os
import signal
import stat
import sys
import time
import zipfile
from contextlib import contextmanager

import pytest
from conftest import ready
from larenor_server.core_backups.component_restore import (
    ComponentRestorePlanError,
    ComponentRestoreRollbackReceipt,
    ComponentRestoreVolumeTarget,
    plan_component_restore,
)
from larenor_server.core_backups.component_restore_recovery import (
    ComponentRestoreRecoveryJournal,
    DurableComponentRestoreCoordinator,
)
from larenor_server.core_backups.component_snapshot_provider import (
    ComponentVolumeSource,
    archive_component_directory,
)
from larenor_server.core_backups.service import (
    ComponentVolumeSnapshot,
    CoreBackupContract,
)
from test_core_backup_component_docker_adapter import (
    effect_reply,
    installed_authority,
    make_roots,
    running_inspect,
)
from test_core_backup_component_restore import capture
from test_volume_effects import engine_server


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
    def exchange_between(first_parent, first, second_parent, second):
        temporary = ".larenor-test-exchange"
        os.rename(
            first,
            temporary,
            src_dir_fd=first_parent,
            dst_dir_fd=first_parent,
        )
        os.rename(
            second,
            first,
            src_dir_fd=second_parent,
            dst_dir_fd=first_parent,
        )
        os.rename(
            temporary,
            second,
            src_dir_fd=first_parent,
            dst_dir_fd=second_parent,
        )

    @staticmethod
    def move(first_parent, first, second_parent, second):
        os.rename(
            first,
            second,
            src_dir_fd=first_parent,
            dst_dir_fd=second_parent,
        )


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
        assert (tmp_path / lease.rollback_name).exists()
        assert engine.finalize_rollback(lease, deadline) is True
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


def test_linux_engine_rejects_operation_id_path_content(tmp_path):
    source, target, _payload_bytes, _target_path = _engine_pair(tmp_path)
    engine = api().LinuxDirectoryRestoreEngine(system=PortableExchange())

    with pytest.raises(ComponentRestorePlanError):
        engine.acquire(
            ((source, target),),
            "../outside".ljust(32, "a"),
            time.monotonic() + 2,
        )

    assert not tuple(tmp_path.glob(".larenor-restore-*"))


def test_linux_engine_removes_unjournaled_stage_during_recovery(tmp_path):
    source, target, payload, target_path = _engine_pair(tmp_path)
    engine = api().LinuxDirectoryRestoreEngine(system=PortableExchange())
    deadline = time.monotonic() + 3
    leases = engine.acquire(((source, target),), "2" * 32, deadline)
    lease = leases[0]
    rollback = engine.capture_rollback(lease, deadline)
    engine.stage(lease, payload, deadline)
    receipt = ComponentRestoreRollbackReceipt(
        resource_id=target.resource_id,
        binding_id=target.binding_id,
        binding_revision=target.binding_revision,
        receipt_id="3" * 64,
        byte_length=rollback[0],
        sha256=rollback[1],
    )
    engine.close(leases)

    recovered = engine.recover(((source, target),), "2" * 32, (receipt,), (), deadline)
    try:
        assert engine.rollback(recovered[0], deadline) is True
        assert (target_path / "current.txt").read_text(encoding="utf-8") == "old"
        assert engine.finalize_rollback(recovered[0], deadline) is True
        assert not tuple(tmp_path.glob(".larenor-restore-*"))
    finally:
        engine.close(recovered)


@pytest.mark.skipif(not hasattr(os, "fork"), reason="requires POSIX fork")
def test_linux_engine_reconciles_real_sigkill_during_publication(tmp_path):
    class KillAfterExchange(PortableExchange):
        @staticmethod
        def exchange_between(first_parent, first, second_parent, second):
            PortableExchange.exchange_between(
                first_parent, first, second_parent, second
            )
            os.kill(os.getpid(), signal.SIGKILL)

    source, target, payload, target_path = _engine_pair(tmp_path)
    engine = api().LinuxDirectoryRestoreEngine(system=KillAfterExchange())
    deadline = time.monotonic() + 5
    leases = engine.acquire(((source, target),), "f" * 32, deadline)
    lease = leases[0]
    try:
        engine.capture_rollback(lease, deadline)
        engine.stage(lease, payload, deadline)
        child = os.fork()
        if child == 0:
            engine.commit(lease, deadline)
            os._exit(0)
        _pid, status = os.waitpid(child, 0)
        assert os.WIFSIGNALED(status)
        assert os.WTERMSIG(status) == signal.SIGKILL

        assert engine.rollback(lease, time.monotonic() + 5) is True
        assert (target_path / "current.txt").read_text(encoding="utf-8") == "old"
        assert engine.finalize_rollback(lease, time.monotonic() + 5) is True
        assert not tuple(tmp_path.glob(".larenor-restore-*"))
    finally:
        engine.close(leases)


@pytest.mark.skipif(sys.platform != "linux", reason="requires Linux renameat2")
def test_linux_native_rename_system_publishes_and_rolls_back(tmp_path):
    source, target, payload, target_path = _engine_pair(tmp_path)
    engine = api().LinuxDirectoryRestoreEngine()
    deadline = time.monotonic() + 5
    leases = engine.acquire(((source, target),), "1" * 32, deadline)
    lease = leases[0]
    try:
        engine.capture_rollback(lease, deadline)
        engine.stage(lease, payload, deadline)
        assert engine.commit(lease, deadline) is True
        assert (target_path / "current.txt").read_text(encoding="utf-8") == "new"
        assert engine.rollback(lease, deadline) is True
        assert (target_path / "current.txt").read_text(encoding="utf-8") == "old"
    finally:
        engine.close(leases)


class PowerLoss(BaseException):
    pass


def _archived_capture(server, receipt, replacements):
    class Boundary:
        @contextmanager
        def quiesce(self, _deadline):
            yield tuple(
                ComponentVolumeSnapshot(
                    serviceId=receipt.service_id,
                    serviceVersion=receipt.service_version,
                    configSchemaVersion=receipt.config_schema_version,
                    dataSchemaVersion=receipt.data_schema_version,
                    volumeId=volume.volume_id,
                    payload=_payload(replacements[volume.volume_id]),
                )
                for volume in receipt.volumes
            )

    app, _client, settings, _clock = server
    pair = ready(server)
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    contract = CoreBackupContract(
        app.state.core.db,
        app.state.core.auth,
        settings,
        component_boundary=Boundary(),
    )
    passphrase = "native component restore acceptance"
    return contract.open_bundle(contract.export(actor, passphrase), passphrase)


def _production_inputs(server, tmp_path, *, checkpoint=None, system=None):
    authority_root = tmp_path / "authority"
    authority_root.mkdir(mode=0o700)
    context = installed_authority(authority_root)
    authority, receipt, binding, _volumes = context.__enter__()
    roots = make_roots(tmp_path / "payloads", binding)
    replacements = {}
    for volume in receipt.volumes:
        root = roots[volume.intent.binding.resource.name]
        (root / "current.txt").write_text("old", encoding="utf-8")
        os.chmod(root / "current.txt", 0o600)
        replacement = tmp_path / "replacement" / volume.volume_id
        replacement.mkdir(parents=True, mode=0o700)
        (replacement / "current.txt").write_text("new", encoding="utf-8")
        os.chmod(replacement / "current.txt", 0o600)
        replacements[volume.volume_id] = replacement
    opened = _archived_capture(server, receipt, replacements)
    restore_authority = api().DurableComponentRestoreAuthority(authority)
    plan = plan_component_restore(opened, restore_authority)
    state = {"paused": False}
    engine_context = engine_server(
        effect_reply(running_inspect(binding, roots), receipt.volumes, state)
    )
    endpoint, calls = engine_context.__enter__()
    controller = importlib.import_module(
        "larenor_server.core_backups.component_docker_adapter"
    ).UnixDockerComponentSnapshotAdapter(
        endpoint,
        authority,
        peer_uid=lambda _: endpoint.owner_uid,
    )
    file_engine = api().LinuxDirectoryRestoreEngine(system=system or PortableExchange())
    boundary = api().LinuxComponentRestoreBoundary(
        restore_authority,
        controller,
        file_engine,
        enabled=True,
    )
    journal = ComponentRestoreRecoveryJournal(
        (tmp_path / "recovery" / "restore.json").absolute(), b"r" * 32
    )
    coordinator = DurableComponentRestoreCoordinator(
        journal, boundary, checkpoint=checkpoint
    )
    return {
        "contexts": (context, engine_context),
        "authority": authority,
        "receipt": receipt,
        "roots": roots,
        "opened": opened,
        "plan": plan,
        "state": state,
        "calls": calls,
        "boundary": boundary,
        "journal": journal,
        "coordinator": coordinator,
        "endpoint": endpoint,
    }


def _close_production_inputs(inputs):
    context, engine_context = inputs["contexts"]
    engine_context.__exit__(None, None, None)
    context.__exit__(None, None, None)


def _restarted_boundary(inputs, *, system=None):
    controller = importlib.import_module(
        "larenor_server.core_backups.component_docker_adapter"
    ).UnixDockerComponentSnapshotAdapter(
        inputs["endpoint"],
        inputs["authority"],
        peer_uid=lambda _: inputs["endpoint"].owner_uid,
    )
    return api().LinuxComponentRestoreBoundary(
        api().DurableComponentRestoreAuthority(inputs["authority"]),
        controller,
        api().LinuxDirectoryRestoreEngine(system=system or PortableExchange()),
        enabled=True,
    )


@pytest.mark.parametrize("lost_phase", ("acquiring", "acquired"))
def test_recovery_never_adopts_unproven_admin_pause(server, tmp_path, lost_phase):
    def checkpoint(state):
        if state["phase"] == lost_phase:
            raise PowerLoss()

    inputs = _production_inputs(server, tmp_path, checkpoint=checkpoint)
    try:
        with pytest.raises(PowerLoss):
            inputs["coordinator"].restore(
                inputs["opened"],
                inputs["plan"],
                deadline=time.monotonic() + 8,
            )
        inputs["state"]["paused"] = True

        restarted = DurableComponentRestoreCoordinator(
            inputs["journal"], _restarted_boundary(inputs)
        )
        with pytest.raises(ComponentRestorePlanError):
            restarted.recover(inputs["plan"], deadline=time.monotonic() + 8)

        assert inputs["state"]["paused"] is True
        assert inputs["journal"].read()["phase"] == lost_phase
    finally:
        _close_production_inputs(inputs)


def test_linux_boundary_restores_and_finalizes_exact_volume_trees(server, tmp_path):
    inputs = _production_inputs(server, tmp_path)
    try:
        receipt = inputs["coordinator"].restore(
            inputs["opened"], inputs["plan"], deadline=time.monotonic() + 8
        )

        assert receipt.snapshot_id == inputs["plan"].snapshot_id
        assert inputs["state"]["paused"] is False
        assert inputs["journal"].exists() is False
        for volume in inputs["receipt"].volumes:
            root = inputs["roots"][volume.intent.binding.resource.name]
            assert (root / "current.txt").read_text(encoding="utf-8") == "new"
            assert not tuple(root.parent.glob(".larenor-restore-*"))
    finally:
        _close_production_inputs(inputs)


@pytest.mark.parametrize(
    "lost_phase", ("quiesced", "staging", "pre_commit", "committed")
)
def test_linux_boundary_restarts_after_power_loss(server, tmp_path, lost_phase):
    def checkpoint(state):
        if state["phase"] == lost_phase:
            raise PowerLoss()

    inputs = _production_inputs(server, tmp_path, checkpoint=checkpoint)
    try:
        with pytest.raises(PowerLoss):
            inputs["coordinator"].restore(
                inputs["opened"],
                inputs["plan"],
                deadline=time.monotonic() + 8,
            )
        assert inputs["state"]["paused"] is True

        controller = importlib.import_module(
            "larenor_server.core_backups.component_docker_adapter"
        ).UnixDockerComponentSnapshotAdapter(
            inputs["endpoint"],
            inputs["authority"],
            peer_uid=lambda _: inputs["endpoint"].owner_uid,
        )
        boundary = api().LinuxComponentRestoreBoundary(
            api().DurableComponentRestoreAuthority(inputs["authority"]),
            controller,
            api().LinuxDirectoryRestoreEngine(system=PortableExchange()),
            enabled=True,
        )
        restarted = DurableComponentRestoreCoordinator(inputs["journal"], boundary)
        assert restarted.recover(inputs["plan"], deadline=time.monotonic() + 8) is True

        assert inputs["state"]["paused"] is False
        assert inputs["journal"].exists() is False
        for volume in inputs["receipt"].volumes:
            root = inputs["roots"][volume.intent.binding.resource.name]
            expected = "new" if lost_phase == "committed" else "old"
            assert (root / "current.txt").read_text(encoding="utf-8") == expected
            assert not tuple(root.parent.glob(".larenor-restore-*"))
    finally:
        _close_production_inputs(inputs)


class PartialCommitPowerLoss(PortableExchange):
    def __init__(self):
        self.operations = 0

    def exchange_between(self, first_parent, first, second_parent, second):
        if self.operations == 1:
            raise PowerLoss()
        super().exchange_between(first_parent, first, second_parent, second)
        self.operations += 1


def test_linux_boundary_recovers_partial_multi_volume_commit(server, tmp_path):
    inputs = _production_inputs(server, tmp_path, system=PartialCommitPowerLoss())
    try:
        with pytest.raises(PowerLoss):
            inputs["coordinator"].restore(
                inputs["opened"],
                inputs["plan"],
                deadline=time.monotonic() + 8,
            )
        assert inputs["state"]["paused"] is True

        controller = importlib.import_module(
            "larenor_server.core_backups.component_docker_adapter"
        ).UnixDockerComponentSnapshotAdapter(
            inputs["endpoint"],
            inputs["authority"],
            peer_uid=lambda _: inputs["endpoint"].owner_uid,
        )
        boundary = api().LinuxComponentRestoreBoundary(
            api().DurableComponentRestoreAuthority(inputs["authority"]),
            controller,
            api().LinuxDirectoryRestoreEngine(system=PortableExchange()),
            enabled=True,
        )
        assert (
            DurableComponentRestoreCoordinator(inputs["journal"], boundary).recover(
                inputs["plan"], deadline=time.monotonic() + 8
            )
            is True
        )

        assert inputs["state"]["paused"] is False
        for volume in inputs["receipt"].volumes:
            root = inputs["roots"][volume.intent.binding.resource.name]
            assert (root / "current.txt").read_text(encoding="utf-8") == "old"
            assert not tuple(root.parent.glob(".larenor-restore-*"))
    finally:
        _close_production_inputs(inputs)


def test_recovery_requiesces_container_unpaused_after_commit_effect(server, tmp_path):
    def checkpoint(state):
        if state["phase"] == "committed":
            raise PowerLoss()

    inputs = _production_inputs(server, tmp_path, checkpoint=checkpoint)
    try:
        with pytest.raises(PowerLoss):
            inputs["coordinator"].restore(
                inputs["opened"],
                inputs["plan"],
                deadline=time.monotonic() + 8,
            )
        inputs["state"]["paused"] = False

        controller = importlib.import_module(
            "larenor_server.core_backups.component_docker_adapter"
        ).UnixDockerComponentSnapshotAdapter(
            inputs["endpoint"],
            inputs["authority"],
            peer_uid=lambda _: inputs["endpoint"].owner_uid,
        )
        file_engine = api().LinuxDirectoryRestoreEngine(system=PortableExchange())
        finalize = file_engine.finalize

        def guarded_finalize(lease, deadline):
            assert inputs["state"]["paused"] is True
            return finalize(lease, deadline)

        file_engine.finalize = guarded_finalize
        boundary = api().LinuxComponentRestoreBoundary(
            api().DurableComponentRestoreAuthority(inputs["authority"]),
            controller,
            file_engine,
            enabled=True,
        )
        assert (
            DurableComponentRestoreCoordinator(inputs["journal"], boundary).recover(
                inputs["plan"], deadline=time.monotonic() + 8
            )
            is True
        )

        assert inputs["state"]["paused"] is False
        for volume in inputs["receipt"].volumes:
            root = inputs["roots"][volume.intent.binding.resource.name]
            assert (root / "current.txt").read_text(encoding="utf-8") == "new"
    finally:
        _close_production_inputs(inputs)


def test_committed_cleanup_is_idempotent_before_phase_persist(server, tmp_path):
    inputs = _production_inputs(server, tmp_path)
    try:
        original_write = inputs["journal"].write

        def fail_committed_finalized(state):
            if state["phase"] == "committed_finalized":
                raise ComponentRestorePlanError()
            return original_write(state)

        inputs["journal"].write = fail_committed_finalized
        with pytest.raises(ComponentRestorePlanError):
            inputs["coordinator"].restore(
                inputs["opened"],
                inputs["plan"],
                deadline=time.monotonic() + 8,
            )

        assert inputs["state"]["paused"] is True
        assert inputs["journal"].read()["phase"] == "committed"
        for volume in inputs["receipt"].volumes:
            root = inputs["roots"][volume.intent.binding.resource.name]
            assert (root / "current.txt").read_text(encoding="utf-8") == "new"
            assert not tuple(root.parent.glob(".larenor-restore-*"))

        inputs["journal"].write = original_write
        assert DurableComponentRestoreCoordinator(
            inputs["journal"], _restarted_boundary(inputs)
        ).recover(inputs["plan"], deadline=time.monotonic() + 8)
        assert inputs["state"]["paused"] is False
        assert inputs["journal"].exists() is False
    finally:
        _close_production_inputs(inputs)


def test_success_cleanup_finishes_before_unpause_allows_service_write(server, tmp_path):
    inputs = _production_inputs(server, tmp_path)
    try:
        controller = inputs["boundary"]._controller
        unpause = controller.unpause

        def unpause_and_write(container_id, deadline):
            assert not tuple(
                path
                for root in inputs["roots"].values()
                for path in root.parent.glob(".larenor-restore-*")
            )
            result = unpause(container_id, deadline)
            for volume in inputs["receipt"].volumes:
                root = inputs["roots"][volume.intent.binding.resource.name]
                (root / "current.txt").write_text("service-live", encoding="utf-8")
            return result

        controller.unpause = unpause_and_write
        inputs["coordinator"].restore(
            inputs["opened"], inputs["plan"], deadline=time.monotonic() + 8
        )

        assert inputs["journal"].exists() is False
        assert inputs["state"]["paused"] is False
        for volume in inputs["receipt"].volumes:
            root = inputs["roots"][volume.intent.binding.resource.name]
            assert (root / "current.txt").read_text(encoding="utf-8") == "service-live"
    finally:
        _close_production_inputs(inputs)


def test_rollback_artifacts_survive_rolled_back_journal_write_failure(server, tmp_path):
    def checkpoint(state):
        if state["phase"] == "pre_commit":
            raise PowerLoss()

    inputs = _production_inputs(server, tmp_path, checkpoint=checkpoint)
    try:
        with pytest.raises(PowerLoss):
            inputs["coordinator"].restore(
                inputs["opened"],
                inputs["plan"],
                deadline=time.monotonic() + 8,
            )
        original_write = inputs["journal"].write

        def fail_rolled_back(state):
            if state["phase"] == "rolled_back":
                raise ComponentRestorePlanError()
            return original_write(state)

        inputs["journal"].write = fail_rolled_back
        with pytest.raises(ComponentRestorePlanError):
            DurableComponentRestoreCoordinator(
                inputs["journal"], _restarted_boundary(inputs)
            ).recover(inputs["plan"], deadline=time.monotonic() + 8)

        assert inputs["state"]["paused"] is True
        assert inputs["journal"].read()["phase"] == "pre_commit"
        for volume in inputs["receipt"].volumes:
            root = inputs["roots"][volume.intent.binding.resource.name]
            assert tuple(root.parent.glob(".larenor-restore-*.rollback"))

        inputs["journal"].write = original_write
        assert DurableComponentRestoreCoordinator(
            inputs["journal"], _restarted_boundary(inputs)
        ).recover(inputs["plan"], deadline=time.monotonic() + 8)
        assert inputs["state"]["paused"] is False
        assert inputs["journal"].exists() is False
        for volume in inputs["receipt"].volumes:
            root = inputs["roots"][volume.intent.binding.resource.name]
            assert (root / "current.txt").read_text(encoding="utf-8") == "old"
            assert not tuple(root.parent.glob(".larenor-restore-*"))
    finally:
        _close_production_inputs(inputs)
