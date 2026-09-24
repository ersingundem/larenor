"""S09.2 durable v3 cross-resource component restore recovery."""

import json
import stat
from dataclasses import replace

import pytest

from larenor_server.core_backups.component_restore import ComponentRestorePlanError
from larenor_server.core_backups.component_restore_recovery import (
    ComponentRestoreRecoveryJournal,
    DurableComponentRestoreCoordinator,
)
from test_core_backup_component_restore import (
    Authority,
    authority_target,
    capture,
    plan_component_restore,
)


class SimulatedCrash(BaseException):
    pass


class DurableState:
    def __init__(self, target, *, partial_commit=False):
        self.target = target
        self.initial = dict(target)
        self.partial_commit = partial_commit
        self.rollback_payloads = {}
        self.staged = {}
        self.events = []
        self.rollback_operations = set()
        self.release_operations = set()


class DurableSession:
    def __init__(self, state, operation_id):
        self.state = state
        self.operation_id = operation_id

    def quiesce(self, targets, _deadline):
        self.state.events.append(("quiesce", self.operation_id, len(targets)))
        return True

    def capture_rollback(self, volume, _deadline):
        from larenor_server.core_backups.component_restore import (
            ComponentRestoreRollbackReceipt,
        )
        import hashlib

        payload = self.state.target[volume.resource_id]
        self.state.rollback_payloads[volume.resource_id] = payload
        self.state.events.append(("snapshot", self.operation_id, volume.resource_id))
        return ComponentRestoreRollbackReceipt(
            resource_id=volume.resource_id,
            binding_id=volume.binding_id,
            binding_revision=volume.binding_revision,
            receipt_id=hashlib.sha256(b"rollback:" + payload).hexdigest(),
            byte_length=len(payload),
            sha256=hashlib.sha256(payload).hexdigest(),
        )

    def stage(self, volume, payload, rollback, _deadline):
        from larenor_server.core_backups.component_restore import (
            ComponentRestoreStageReceipt,
        )
        import hashlib

        self.state.staged[volume.resource_id] = payload
        self.state.events.append(("stage", self.operation_id, volume.resource_id))
        return ComponentRestoreStageReceipt(
            resource_id=volume.resource_id,
            binding_id=volume.binding_id,
            binding_revision=volume.binding_revision,
            rollback_receipt_id=rollback.receipt_id,
            stage_id=hashlib.sha256(b"stage:" + payload).hexdigest(),
            byte_length=len(payload),
            sha256=hashlib.sha256(payload).hexdigest(),
        )

    def revalidate(self, _plan, _deadline):
        self.state.events.append(("revalidate", self.operation_id))
        return True

    def commit(self, stages, _rollbacks, _deadline):
        self.state.events.append(("commit", self.operation_id))
        for index, receipt in enumerate(stages):
            self.state.target[receipt.resource_id] = self.state.staged[
                receipt.resource_id
            ]
            if self.state.partial_commit and index == 0:
                raise SimulatedCrash()
        return True

    def rollback(self, _rollbacks, _stages):
        if self.operation_id not in self.state.rollback_operations:
            self.state.rollback_operations.add(self.operation_id)
            self.state.target.update(self.state.rollback_payloads)
            self.state.staged.clear()
        self.state.events.append(("rollback", self.operation_id))
        return True

    def release(self):
        self.state.release_operations.add(self.operation_id)
        self.state.events.append(("release", self.operation_id))
        return True


class DurableBoundary:
    def __init__(self, state):
        self.state = state

    def acquire_durable(self, plan, operation_id, _deadline):
        self.state.events.append(("acquire", operation_id, plan.snapshot_id))
        return DurableSession(self.state, operation_id)

    def recover_durable(self, plan, operation_id, _deadline):
        self.state.events.append(("recover", operation_id, plan.snapshot_id))
        return DurableSession(self.state, operation_id)


def durable_inputs(server, tmp_path, *, partial_commit=False, checkpoint=None):
    opened = capture(server)
    plan = plan_component_restore(opened, Authority((authority_target(),)))
    target = {
        item.resource_id: b"old:" + item.resource_id.encode()
        for item in plan.targets[0].volumes
    }
    state = DurableState(target, partial_commit=partial_commit)
    boundary = DurableBoundary(state)
    journal = ComponentRestoreRecoveryJournal(
        tmp_path / "component-restore-v3.json",
        b"j" * 32,
    )
    coordinator = DurableComponentRestoreCoordinator(
        journal,
        boundary,
        monotonic=lambda: 0.0,
        checkpoint=checkpoint,
    )
    return opened, plan, state, journal, coordinator


@pytest.mark.parametrize(
    "crash_phase,occurrence",
    [
        ("acquired", 1),
        ("quiesced", 1),
        ("rollback_snapshots", 1),
        ("staging", 1),
        ("pre_commit", 1),
    ],
)
def test_restart_reconciles_each_precommit_crash_once(
    server, tmp_path, crash_phase, occurrence
):
    seen = 0

    def checkpoint(state):
        nonlocal seen
        if state["phase"] == crash_phase:
            seen += 1
            if seen == occurrence:
                raise SimulatedCrash()

    opened, plan, state, journal, coordinator = durable_inputs(
        server,
        tmp_path,
        checkpoint=checkpoint,
    )
    with pytest.raises(SimulatedCrash):
        coordinator.restore(opened, plan, deadline=10.0)
    assert journal.exists()
    assert state.target == state.initial

    restarted = DurableComponentRestoreCoordinator(
        journal,
        DurableBoundary(state),
        monotonic=lambda: 0.0,
    )
    assert restarted.recover(plan, deadline=10.0) is True
    assert state.target == state.initial
    assert len(state.rollback_operations) == 1
    assert len(state.release_operations) == 1
    assert sum(event[0] == "rollback" for event in state.events) == 1
    assert sum(event[0] == "release" for event in state.events) == 1
    assert restarted.recover(plan, deadline=10.0) is False
    assert len(state.rollback_operations) == 1
    assert len(state.release_operations) == 1


def test_partial_commit_is_rolled_back_after_restart_and_recovery_is_idempotent(
    server, tmp_path
):
    opened, plan, state, journal, coordinator = durable_inputs(
        server,
        tmp_path,
        partial_commit=True,
    )

    with pytest.raises(SimulatedCrash):
        coordinator.restore(opened, plan, deadline=10.0)
    assert journal.read()["phase"] == "pre_commit"
    assert state.target != state.initial

    state.partial_commit = False
    restarted = DurableComponentRestoreCoordinator(
        journal,
        DurableBoundary(state),
        monotonic=lambda: 0.0,
    )
    assert restarted.recover(plan, deadline=10.0) is True
    assert state.target == state.initial
    assert restarted.recover(plan, deadline=10.0) is False
    assert len(state.rollback_operations) == 1
    assert len(state.release_operations) == 1


def test_successful_durable_batch_clears_journal_after_exact_release(server, tmp_path):
    opened, plan, state, journal, coordinator = durable_inputs(server, tmp_path)

    receipt = coordinator.restore(opened, plan, deadline=10.0)

    assert not journal.exists()
    assert state.target == {
        item.resource_id: opened.payloads[item.resource_id]
        for item in plan.targets[0].volumes
    }
    assert receipt.snapshot_id == plan.snapshot_id
    assert not state.rollback_operations
    assert len(state.release_operations) == 1
    assert coordinator.recover(plan, deadline=10.0) is False


@pytest.mark.parametrize("recovery_phase", ["rolled_back", "released"])
def test_recovery_restart_skips_completed_rollback_or_release_exactly_once(
    server, tmp_path, recovery_phase
):
    opened, plan, state, journal, coordinator = durable_inputs(
        server,
        tmp_path,
        partial_commit=True,
    )
    with pytest.raises(SimulatedCrash):
        coordinator.restore(opened, plan, deadline=10.0)
    state.partial_commit = False

    def checkpoint(value):
        if value["phase"] == recovery_phase:
            raise SimulatedCrash()

    first_restart = DurableComponentRestoreCoordinator(
        journal,
        DurableBoundary(state),
        monotonic=lambda: 0.0,
        checkpoint=checkpoint,
    )
    with pytest.raises(SimulatedCrash):
        first_restart.recover(plan, deadline=10.0)
    assert journal.read()["phase"] == recovery_phase

    second_restart = DurableComponentRestoreCoordinator(
        journal,
        DurableBoundary(state),
        monotonic=lambda: 0.0,
    )
    assert second_restart.recover(plan, deadline=10.0) is True
    assert state.target == state.initial
    assert sum(event[0] == "rollback" for event in state.events) == 1
    assert sum(event[0] == "release" for event in state.events) == 1
    assert second_restart.recover(plan, deadline=10.0) is False


def test_v3_journal_is_private_authenticated_bounded_and_fail_closed(
    server, tmp_path
):
    def checkpoint(state):
        if state["phase"] == "staging":
            raise SimulatedCrash()

    opened, plan, state, journal, coordinator = durable_inputs(
        server,
        tmp_path,
        checkpoint=checkpoint,
    )
    with pytest.raises(SimulatedCrash):
        coordinator.restore(opened, plan, deadline=10.0)

    raw = journal.path.read_bytes()
    parsed = json.loads(raw)
    assert parsed["version"] == 3
    assert len(parsed["authentication"]) == 64
    assert stat.S_IMODE(journal.path.stat().st_mode) == 0o600
    assert len(raw) < 256 * 1024
    assert b"restorable" not in raw
    assert b"old:component" not in raw
    assert b"/private/" not in raw

    foreign = replace(
        plan,
        targets=(
            replace(
                plan.targets[0],
                installation_revision=plan.targets[0].installation_revision + 1,
            ),
        ),
    )
    with pytest.raises(ComponentRestorePlanError):
        DurableComponentRestoreCoordinator(
            journal,
            DurableBoundary(state),
            monotonic=lambda: 0.0,
        ).recover(foreign, deadline=10.0)
    assert not state.rollback_operations
    assert not state.release_operations

    parsed["phase"] = "committed"
    journal.path.write_text(json.dumps(parsed, sort_keys=True, separators=(",", ":")))
    with pytest.raises(
        ComponentRestorePlanError,
        match="^component_restore_unavailable$",
    ):
        DurableComponentRestoreCoordinator(
            journal,
            DurableBoundary(state),
            monotonic=lambda: 0.0,
        ).recover(plan, deadline=10.0)
    assert state.target == state.initial
    assert not state.rollback_operations
    assert not state.release_operations


def test_recovery_journal_serializes_cross_process_owners(tmp_path):
    path = tmp_path / "component-restore-v3.json"
    first = ComponentRestoreRecoveryJournal(path, b"j" * 32)
    second = ComponentRestoreRecoveryJournal(path, b"j" * 32)
    descriptor = first.acquire_lock()
    try:
        with pytest.raises(ComponentRestorePlanError):
            second.acquire_lock()
    finally:
        first.release_lock(descriptor)

    descriptor = second.acquire_lock()
    second.release_lock(descriptor)


def test_default_durable_boundary_keeps_component_restore_disabled(
    server, tmp_path
):
    opened = capture(server)
    plan = plan_component_restore(opened, Authority((authority_target(),)))
    journal = ComponentRestoreRecoveryJournal(
        tmp_path / "component-restore-v3.json",
        b"j" * 32,
    )

    with pytest.raises(ComponentRestorePlanError):
        DurableComponentRestoreCoordinator(
            journal,
            monotonic=lambda: 0.0,
        ).restore(opened, plan, deadline=10.0)
    assert not journal.exists()
