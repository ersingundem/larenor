"""Real protected files/decode with authenticated upstream protocol fixtures."""
from dataclasses import replace
import json
import os
import shutil
import tempfile
import threading
import time
from pathlib import Path

import pytest

from larenor_server.media_archive_actions.engine import MediaArchiveActionEngine, ResolvedArchiveActionSource
from larenor_server.media_archive_actions.cleanup_executor import (
    ResolvedDuplicateCleanup, ResolvedDuplicateCleanupItem, cleanup_effects,
)
from larenor_server.media_archive_actions.file_store import MediaArchiveFileStore
from larenor_server.media_archive_actions.journal import MediaArchiveActionJournal, action_command_digest
from larenor_server.media_archive_actions.models import PrivateArchiveActionCommand
from larenor_server.media_archive_actions.terminal_store import UnmanicTerminalStore
from larenor_server.media_archive_actions.unmanic import UnmanicAdapter, UnmanicResponse
from larenor_server.media_archive_actions.worker_ipc import MediaArchiveActionWorkerClient, MediaArchiveActionWorkerServer
from test_media_archive_unmanic_terminal_store import KEY, NOW, body, headers
from test_media_archive_verifier import media


class Resolver:
    def __init__(self, cmd, path):
        self.allowed = True
        target = cmd.target
        self.source = ResolvedArchiveActionSource(
            action_command_digest(cmd), str(path), 7, target.sourceItemId,
            target.mediaKey, target.sourceSizeBytes, target.sourceCodec, target.durationSeconds)

    def resolve(self, _command, *, deadline):
        if not self.allowed:
            raise ValueError("authority changed")
        return self.source

    def authorize(self, _command, *, deadline):
        return self.allowed

    def authorize_retained(
            self, command, source_command, source_path, *, deadline):
        return (self.allowed
                and command.operation == "cleanup_retained_original"
                and command.target.sourceOperationId
                == source_command.operationId
                and source_path == self.source.path
                and time.monotonic() < deadline)


class Exchange:
    """Unmanic protocol/callback fixture; output is real encoded media."""
    def __init__(self, output, terminal_store):
        self.output, self.terminals = output, terminal_store
        self.created = []
        self.mode = "success"

    def __call__(self, request, deadline):
        data = json.loads(request.body)
        path = data["path"]
        if request.path.endswith("/pending/test"):
            value = {"path": path, "library_id": 7, "library_name": "Archive test",
                     "add_file_to_pending_tasks": True, "issues": [], "decision_plugin": None}
        else:
            assert request.path.endswith("/pending/create")
            self.created.append(path)
            if self.mode == "lost_ack":
                raise TimeoutError("simulated accepted task, acknowledgement lost")
            if self.mode != "waiting":
                shutil.copyfile(self.output, path)
                raw = body(sourcePath=path, destinationPath=path, destinationFiles=[path])
                if self.mode == 'failed':
                    raw = body(sourcePath=path, destinationPath=path, destinationFiles=[], taskSuccess=False)
                self.terminals.ingest(headers(raw), raw)
            value = {"id": 31, "abspath": path, "priority": 0, "type": "local",
                     "status": "pending", "library_id": 7}
        return UnmanicResponse(200, "application/json", json.dumps(value).encode())


@pytest.fixture
def engine(tmp_path, media):
    roots = {name: tmp_path / name for name in ("library", "work", "retained", "journal", "terminal", "ipc")}
    for root in roots.values():
        root.mkdir(mode=0o700)
    source = roots["library"] / "movie.mkv"
    shutil.copyfile(media[2], source)
    source.chmod(0o600)
    cmd = media[4]
    journal = MediaArchiveActionJournal(roots["journal"])
    files = MediaArchiveFileStore(roots["retained"], roots["work"], [roots["library"]],
                                 quota_bytes=cmd.reservedBytes * 4)
    terminals = UnmanicTerminalStore(roots["terminal"], KEY, clock=lambda: NOW)
    resolver = Resolver(cmd, source)
    exchange = Exchange(media[3], terminals)
    handler = MediaArchiveActionEngine(journal, files, UnmanicAdapter(exchange), terminals, media[0], resolver)
    yield handler, cmd, source, exchange, resolver, roots
    handler.close()
    terminals.close()
    journal.close()


def wait_result(handler, cmd):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        receipt = handler.reconcile(cmd, deadline=time.monotonic()+5, cancelled=lambda: False)
        if receipt.state != "running":
            return receipt
        time.sleep(0.05)
    pytest.fail("archive fixture did not terminate")


def cleanup_command(source, *, operation_id="9" * 32):
    return PrivateArchiveActionCommand(
        operationId=operation_id,
        operation="cleanup_retained_original",
        authority=source.authority,
        candidate=source.candidate,
        sourceJobId="8" * 32,
        sourceJobRevision=3,
        target={
            "targetType": "retained_original",
            "sourceOperationId": source.operationId,
        },
        evidenceDigest="e" * 64,
        reservedBytes=0,
        retainOriginal=False,
    )


def duplicate_command(source, *, operation_id="7" * 32):
    return PrivateArchiveActionCommand(
        operationId=operation_id, operation="cleanup_duplicate",
        authority=source.authority,
        candidate={
            "candidateId": "7" * 64, "kind": "duplicate",
            "title": "Duplicate", "potentialBytes": 100,
            "confidence": "high", "comparison": {
                "basis": "keep_largest_copy", "observedBytes": 200,
                "estimatedRetainedBytes": 100,
                "estimatedSavingBytes": 100,
            },
            "evidence": ["content_hash_match", "multiple_playable_files",
                         "largest_copy_excluded"], "actionType": "cleanup",
        },
        target={"targetType": "duplicate", "keepItemId": "1" * 32,
                "deleteItemIds": ["2" * 32]},
        evidenceDigest="7" * 64, reservedBytes=0, retainOriginal=False)


class CleanupCatalog:
    def __init__(self, command):
        self.plan = ResolvedDuplicateCleanup(
            action_command_digest(command), "6" * 64,
            ResolvedDuplicateCleanupItem(
                "1" * 32, "movie:tmdb:1", "radarr", 11,
                "/media/keep.mkv", "/data/movies/keep.mkv", 100),
            (ResolvedDuplicateCleanupItem(
                "2" * 32, "movie:tmdb:1", "radarr", 12,
                "/media/delete.mkv", "/data/movies/delete.mkv", 100),))

    def resolve(self, _command, *, deadline, require_delete_present=True):
        assert time.monotonic() < deadline
        return self.plan

    def authorize(self, _command, plan, *, deadline):
        return plan == self.plan and time.monotonic() < deadline


class CleanupExecutor:
    def __init__(self, plan):
        self.present = {effect.effectId for effect in cleanup_effects(plan)}
        self.mutations = []

    def preflight(self, _command, plan, *, deadline):
        assert self.present == {effect.effectId for effect in cleanup_effects(plan)}
        return plan.planDigest

    def observe(self, _command, _plan, effect, *, deadline):
        return effect.effectId in self.present

    def mutate(self, _command, _plan, effect, *, deadline):
        self.mutations.append(effect.effectId)
        self.present.remove(effect.effectId)
        return True

    def authorize(self, _command, _plan, *, deadline):
        return time.monotonic() < deadline


def test_async_engine_installs_real_verified_output_and_keeps_original(engine, media):
    handler, cmd, source, exchange, _resolver, _roots = engine
    assert handler.preview(cmd, deadline=time.monotonic()+5, gate=lambda: True).state == "ready"
    receipt = handler.execute(cmd, deadline=time.monotonic()+5, cancelled=lambda: False)
    assert receipt.state == "running" and not receipt.retainedOriginal
    result = wait_result(handler, cmd)
    assert result.state == "succeeded" and result.retainedOriginal and result.proofDigest
    binding = handler.files.lookup(cmd)
    assert source.read_bytes() == media[3].read_bytes()
    assert handler.files.inspect_original(binding)[1] == media[2].stat().st_size
    assert len(exchange.created) == 1
    assert handler.execute(
        cmd, deadline=time.monotonic()+5,
        cancelled=lambda: False) == result
    assert len(exchange.created) == 1


def test_retained_cleanup_uses_source_proof_and_keeps_installed_output(
        engine, media):
    handler, cmd, source, exchange, _resolver, _roots = engine
    handler.execute(cmd, deadline=time.monotonic()+5, cancelled=lambda: False)
    assert wait_result(handler, cmd).state == "succeeded"
    cleanup = cleanup_command(cmd)

    preview = handler.preview(
        cleanup, deadline=time.monotonic()+5, gate=lambda: True)
    assert (preview.requiredBytes, preview.originalWillBeRetained) == (0, False)
    assert handler.execute(
        cleanup, deadline=time.monotonic()+5,
        cancelled=lambda: False).state == "running"
    result = wait_result(handler, cleanup)

    assert result.state == "succeeded"
    assert not result.retainedOriginal and result.proofDigest
    assert source.read_bytes() == media[3].read_bytes()
    binding = handler.files.lookup(cmd)
    assert not Path(binding.retainedPath).exists()
    assert len(exchange.created) == 1
    with handler.journal.locked():
        record = handler.journal.get(cleanup.operationId)
        source_record = handler.journal.get(cmd.operationId)
    assert record.evidence.cleanupDeleteIntent
    assert record.evidence.cleanupVerified
    assert (record.evidence.cleanupSourceProofDigest
            == source_record.receipt.proofDigest)


def test_duplicate_cleanup_records_each_intent_and_verified_absence(engine):
    handler, source, _path, _exchange, resolver, _roots = engine
    command = duplicate_command(source)
    catalog = CleanupCatalog(command)
    executor = CleanupExecutor(catalog.plan)
    replacement = MediaArchiveActionEngine(
        handler.journal, handler.files, handler.unmanic, handler.terminals,
        handler.verifier, resolver, cleanup_catalog=catalog,
        cleanup_executor=executor)
    try:
        assert replacement.preview(
            command, deadline=time.monotonic()+5,
            gate=lambda: True).state == "ready"
        assert replacement.execute(
            command, deadline=time.monotonic()+5,
            cancelled=lambda: False).state == "running"
        result = wait_result(replacement, command)
        assert result.state == "succeeded" and result.proofDigest
        with replacement.journal.locked():
            evidence = replacement.journal.get(command.operationId).evidence
        expected = [effect.effectId for effect in cleanup_effects(catalog.plan)]
        assert evidence.cleanupIntents == expected
        assert evidence.cleanupCompleted == expected
        assert evidence.cleanupVerified and executor.mutations == expected
    finally:
        replacement.close()


def test_duplicate_cleanup_lost_completion_record_never_claims_absence(
        engine, monkeypatch):
    handler, source, _path, _exchange, resolver, _roots = engine
    command = duplicate_command(source, operation_id="6" * 32)
    catalog = CleanupCatalog(command)
    executor = CleanupExecutor(catalog.plan)
    transition = handler.journal.transition
    interrupted = False

    def lose_after_upstream_delete(record, state, **kwargs):
        nonlocal interrupted
        evidence = kwargs.get("evidence")
        if (not interrupted and evidence is not None
                and evidence.cleanupCompleted):
            interrupted = True
            raise OSError("simulated interruption before completion record")
        return transition(record, state, **kwargs)

    monkeypatch.setattr(handler.journal, "transition", lose_after_upstream_delete)
    first = MediaArchiveActionEngine(
        handler.journal, handler.files, handler.unmanic, handler.terminals,
        handler.verifier, resolver, cleanup_catalog=catalog,
        cleanup_executor=executor)
    try:
        first.execute(
            command, deadline=time.monotonic()+5,
            cancelled=lambda: False)
        result = wait_result(first, command)
        assert result.state == "needs_attention"
        assert result.errorCode == "effect_unknown"
        assert len(executor.mutations) == 1
        with first.journal.locked():
            evidence = first.journal.get(command.operationId).evidence
        assert len(evidence.cleanupIntents) == 1
        assert evidence.cleanupCompleted == []
    finally:
        first.close()

    monkeypatch.setattr(handler.journal, "transition", transition)
    restarted = MediaArchiveActionEngine(
        handler.journal, handler.files, handler.unmanic, handler.terminals,
        handler.verifier, resolver, cleanup_catalog=catalog,
        cleanup_executor=executor)
    try:
        assert restarted.reconcile(
            command, deadline=time.monotonic()+5,
            cancelled=lambda: False) == result
        assert restarted.execute(
            command, deadline=time.monotonic()+5,
            cancelled=lambda: False) == result
        assert len(executor.mutations) == 1
    finally:
        restarted.close()


def test_cleanup_lost_delete_receipt_recovers_only_from_durable_intent(
        engine, media, monkeypatch):
    handler, cmd, source, _exchange, resolver, _roots = engine
    handler.execute(cmd, deadline=time.monotonic()+5, cancelled=lambda: False)
    assert wait_result(handler, cmd).state == "succeeded"
    cleanup = cleanup_command(cmd, operation_id="a" * 32)
    transition = handler.journal.transition

    def lose_after_delete(record, state, **kwargs):
        evidence = kwargs.get("evidence")
        if (record.command.operation == "cleanup_retained_original"
                and evidence is not None and evidence.cleanupVerified):
            raise OSError("simulated interruption after retained delete")
        return transition(record, state, **kwargs)

    monkeypatch.setattr(handler.journal, "transition", lose_after_delete)
    handler.execute(cleanup, deadline=time.monotonic()+5,
                    cancelled=lambda: False)
    deadline = time.monotonic()+10
    while handler._threads and time.monotonic() < deadline:
        time.sleep(.02)
    binding = handler.files.lookup(cmd)
    assert not Path(binding.retainedPath).exists()
    with handler.journal.locked():
        interrupted = handler.journal.get(cleanup.operationId)
    assert interrupted.state == "needs_attention"
    assert interrupted.evidence.cleanupDeleteIntent
    assert not interrupted.evidence.cleanupVerified

    monkeypatch.setattr(handler.journal, "transition", transition)
    replacement = MediaArchiveActionEngine(
        handler.journal, handler.files, handler.unmanic, handler.terminals,
        handler.verifier, resolver)
    try:
        recovered = wait_result(replacement, cleanup)
        assert recovered.state == "succeeded" and recovered.proofDigest
        assert not recovered.retainedOriginal
        assert source.read_bytes() == media[3].read_bytes()
    finally:
        replacement.close()


def test_unrelated_missing_original_and_installed_hash_drift_never_succeed(
        engine, media):
    handler, cmd, source, _exchange, _resolver, _roots = engine
    handler.execute(cmd, deadline=time.monotonic()+5, cancelled=lambda: False)
    assert wait_result(handler, cmd).state == "succeeded"
    binding = handler.files.lookup(cmd)
    # Same-size installed tampering is detected by the full hash before any
    # delete intent is recorded.
    source.write_bytes(b"z" * source.stat().st_size)
    drift = cleanup_command(cmd, operation_id="d" * 32)
    handler.execute(drift, deadline=time.monotonic()+5,
                    cancelled=lambda: False)
    result = wait_result(handler, drift)
    assert result.state == "needs_attention"
    assert Path(binding.retainedPath).exists()
    with handler.journal.locked():
        record = handler.journal.get(drift.operationId)
    assert not record.evidence.cleanupDeleteIntent

    source.write_bytes(media[3].read_bytes())
    cleanup = cleanup_command(cmd, operation_id="c" * 32)
    Path(binding.retainedPath).unlink()
    with pytest.raises(Exception):
        handler.execute(cleanup, deadline=time.monotonic()+5,
                        cancelled=lambda: False)
    with handler.journal.locked():
        assert handler.journal.get(cleanup.operationId) is None


def test_plan_writer_precedes_every_unmanic_effect(engine):
    handler, cmd, _source, exchange, resolver, _roots = engine
    calls = []

    def writer(actual, staged, *, deadline):
        assert actual == cmd and staged.operationId == cmd.operationId
        assert time.monotonic() < deadline and exchange.created == []
        calls.append(staged.workPath)
        raise RuntimeError("plan publication failed")

    replacement = MediaArchiveActionEngine(
        handler.journal, handler.files, handler.unmanic, handler.terminals,
        handler.verifier, resolver, plan_writer=writer)
    try:
        replacement.execute(
            cmd, deadline=time.monotonic()+5, cancelled=lambda: False)
        result = wait_result(replacement, cmd)
        assert result.state == "needs_attention"
        assert calls and exchange.created == []
    finally:
        replacement.close()


def test_lost_provider_ack_is_never_resubmitted_or_installed(engine, media):
    handler, cmd, source, exchange, _resolver, _roots = engine
    exchange.mode = "lost_ack"
    handler.execute(cmd, deadline=time.monotonic()+5, cancelled=lambda: False)
    result = wait_result(handler, cmd)
    assert result.state == "needs_attention" and result.errorCode == "effect_unknown"
    assert result.retainedOriginal
    for _ in range(3):
        assert handler.reconcile(cmd, deadline=time.monotonic()+5, cancelled=lambda: False) == result
        assert handler.execute(cmd, deadline=time.monotonic()+5, cancelled=lambda: False) == result
    assert not handler._threads
    handler.close()
    assert len(exchange.created) == 1
    assert source.read_bytes() == media[2].read_bytes()


def test_failed_terminal_without_output_is_not_polled_as_running(engine, media):
    handler, cmd, source, exchange, _resolver, _roots = engine
    exchange.mode = 'failed'
    handler.execute(cmd, deadline=time.monotonic()+5, cancelled=lambda: False)
    result = wait_result(handler, cmd)
    assert result.state == 'failed' and result.errorCode == 'verification_failed'
    assert result.retainedOriginal and source.read_bytes() == media[2].read_bytes()
    assert handler.reconcile(cmd, deadline=time.monotonic()+5, cancelled=lambda: False) == result
    assert len(exchange.created) == 1


def test_ipc_cancel_is_transmitted_and_original_is_never_replaced(engine, media):
    handler, cmd, source, exchange, _resolver, roots = engine
    exchange.mode = "waiting"
    with tempfile.TemporaryDirectory(prefix="la-", dir="/tmp") as socket_root, \
            MediaArchiveActionWorkerServer(str(Path(socket_root) / "archive.sock"), handler):
        client = MediaArchiveActionWorkerClient(str(Path(socket_root) / "archive.sock"))
        client.execute(cmd, deadline=time.monotonic()+5, cancelled=lambda: False)
        deadline = time.monotonic()+5
        while not exchange.created and time.monotonic() < deadline:
            client.reconcile(cmd, deadline=time.monotonic()+5, cancelled=lambda: False)
            time.sleep(0.05)
        with pytest.raises(Exception):
            client.reconcile(cmd, deadline=time.monotonic()+5, cancelled=lambda: True)
        while handler._threads and time.monotonic() < deadline:
            time.sleep(0.05)
        with handler.journal.locked():
            record = handler.journal.get(cmd.operationId)
        assert record.state == "needs_attention"
        assert record.evidence.cancelRequested and record.receipt.errorCode == "cancel_unknown"
        assert source.read_bytes() == media[2].read_bytes()
        assert handler.files.inspect_original(handler.files.lookup(cmd))[1] == cmd.reservedBytes


def test_action_ipc_group_mode_does_not_replace_peer_uid_check(engine):
    handler, _cmd, _source, _exchange, _resolver, _roots = engine
    with tempfile.TemporaryDirectory(prefix="la-", dir="/tmp") as socket_root:
        root = Path(socket_root)
        root.chmod(0o770)
        os.chown(root, -1, os.getgid())
        path = str(root / "archive.sock")
        server = MediaArchiveActionWorkerServer(
            path, handler, peer_uid=os.getuid(), socket_gid=os.getgid())
        server.start()
        try:
            info = os.stat(path, follow_symlinks=False)
            assert (info.st_uid, info.st_gid, info.st_mode & 0o777) == (
                os.getuid(), os.getgid(), 0o660)
            assert MediaArchiveActionWorkerClient(path).status()["provider"] == "unmanic"
            server.peer_uid = os.getuid() + 1
            with pytest.raises(Exception, match="invalid_response"):
                MediaArchiveActionWorkerClient(path).status()
        finally:
            server.close()


def test_pre_effect_wrong_source_profile_has_no_mutation(engine, media):
    handler, cmd, source, exchange, resolver, _roots = engine
    resolver.source = replace(resolver.source, sourceCodec="vc1")
    with pytest.raises(Exception):
        handler.preview(cmd, deadline=time.monotonic()+5, gate=lambda: True)
    with pytest.raises(Exception):
        handler.execute(cmd, deadline=time.monotonic()+5, cancelled=lambda: False)
    assert exchange.created == []
    assert source.read_bytes() == media[2].read_bytes()
    assert handler.files.retained_bytes() == 0


def test_authorization_lease_expiry_preserves_source_and_protected_original(engine, media):
    handler, cmd, source, exchange, _resolver, _roots = engine
    exchange.mode = "waiting"
    handler.execute(cmd, deadline=time.monotonic()+5, cancelled=lambda: False)
    deadline = time.monotonic()+5
    while not exchange.created and time.monotonic() < deadline:
        time.sleep(0.02)
    with handler._lock:
        handler._leases[cmd.operationId] = time.monotonic()-1
    while handler._threads and time.monotonic() < deadline:
        time.sleep(0.02)
    with handler.journal.locked():
        record = handler.journal.get(cmd.operationId)
    assert record.receipt.errorCode == "authority_changed"
    assert source.read_bytes() == media[2].read_bytes()
    assert handler.files.inspect_original(handler.files.lookup(cmd))[1] == cmd.reservedBytes


def test_lost_install_receipt_recovers_from_actual_installed_hash(engine, media, monkeypatch):
    handler, cmd, source, exchange, resolver, _roots = engine
    transition = handler.journal.transition

    def lost_receipt(record, state, **kwargs):
        if state == "succeeded":
            raise OSError("simulated interruption after durable replacement")
        return transition(record, state, **kwargs)

    monkeypatch.setattr(handler.journal, "transition", lost_receipt)
    handler.execute(cmd, deadline=time.monotonic()+5, cancelled=lambda: False)
    deadline = time.monotonic()+15
    while handler._threads and time.monotonic() < deadline:
        time.sleep(0.02)
    assert not handler._threads
    with handler.journal.locked():
        record = handler.journal.get(cmd.operationId)
    assert record.state == "needs_attention" and record.evidence.installIntent
    assert not record.evidence.outputInstalled
    assert source.read_bytes() == media[3].read_bytes()
    monkeypatch.setattr(handler.journal, "transition", transition)
    # Replaced files no longer have the old source profile. Recovery must use
    # current authority plus installed digest, not demand obsolete source bytes.
    resolver.source = replace(resolver.source, sourceCodec="hevc")
    replacement = MediaArchiveActionEngine(handler.journal, handler.files, handler.unmanic,
        handler.terminals, handler.verifier, resolver)
    try:
        result = wait_result(replacement, cmd)
        assert result.state == "succeeded" and result.proofDigest and result.retainedOriginal
        assert len(exchange.created) == 1
        assert handler.files.inspect_original(handler.files.lookup(cmd))[1] == cmd.reservedBytes
    finally:
        replacement.close()


def test_cancel_during_unknown_submission_is_never_reported_cancelled(engine, media):
    handler, cmd, source, exchange, _resolver, _roots = engine
    exchange.mode = "lost_ack"
    cancelled = threading.Event()
    original_exchange = handler.unmanic._exchange

    def lose_ack_after_cancel(request, deadline):
        if request.path.endswith("/pending/create"):
            cancelled.set()
            handler._renew(cmd, cancelled.is_set)
        return original_exchange(request, deadline)

    handler.unmanic._exchange = lose_ack_after_cancel
    handler.execute(cmd, deadline=time.monotonic()+5, cancelled=cancelled.is_set)
    result = wait_result(handler, cmd)
    assert result.state == "needs_attention" and result.errorCode == "cancel_unknown"
    assert result.retainedOriginal and len(exchange.created) == 1
    assert source.read_bytes() == media[2].read_bytes()
