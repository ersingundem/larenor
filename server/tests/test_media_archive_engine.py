"""Real protected files/decode with authenticated upstream protocol fixtures."""
from dataclasses import replace
import json
import shutil
import tempfile
import threading
import time
from pathlib import Path

import pytest

from larenor_server.media_archive_actions.engine import MediaArchiveActionEngine, ResolvedArchiveActionSource
from larenor_server.media_archive_actions.file_store import MediaArchiveFileStore
from larenor_server.media_archive_actions.journal import MediaArchiveActionJournal, action_command_digest
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
    assert handler.execute(cmd, deadline=time.monotonic()+5, cancelled=lambda: False) == result
    assert len(exchange.created) == 1


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
