"""Durable asynchronous archive effects, independent of the IPC deadline.

Source resolution must come from the authenticated collector's exact authority,
never an item ID converted to a path by guessing. Unknown provider submissions
are never repeated. Long jobs require renewed Core authorization before install.
"""

from dataclasses import dataclass
import hmac
from pathlib import Path
import threading
import time

from .file_store import (
    ArchiveFileStoreError, ArchiveRetainedCleanupProof,
    MediaArchiveFileStore,
)
from .journal import (
    ArchiveActionEffectEvidence, ArchiveActionJournalError,
    MediaArchiveActionJournal, action_command_digest,
)
from .models import ArchiveActionWorkerPreview, ArchiveActionWorkerReceipt
from .unmanic import UnmanicAdapter
from .verifier import ArchiveVerificationError, MediaArchiveOutputVerifier
from .worker_ipc import MediaArchiveActionWorkerError


@dataclass(frozen=True, repr=False)
class ResolvedArchiveActionSource:
    commandDigest: str
    path: str
    libraryId: int
    sourceItemId: str
    mediaKey: str
    sourceSizeBytes: int
    sourceCodec: str
    durationSeconds: int

    def __repr__(self):
        return "ResolvedArchiveActionSource(<private>)"


class MediaArchiveActionEngine:
    """One mutation at a time, with protected copies and durable terminal proof."""

    available = True
    LEASE_SECONDS = 15

    def __init__(self, journal, files, unmanic, terminals, verifier, resolver,
                 plan_writer=None):
        if (type(journal) is not MediaArchiveActionJournal
                or type(files) is not MediaArchiveFileStore
                or type(unmanic) is not UnmanicAdapter
                or type(verifier) is not MediaArchiveOutputVerifier
                or not callable(getattr(terminals, "lookup_terminal", None))
                or not callable(getattr(resolver, "resolve", None))
                or not callable(getattr(resolver, "authorize", None))
                or not callable(getattr(resolver, "authorize_retained", None))
                or plan_writer is not None and not callable(plan_writer)):
            raise ValueError("archive_engine_unavailable")
        self.journal, self.files, self.unmanic = journal, files, unmanic
        self.terminals, self.verifier, self.resolver = terminals, verifier, resolver
        self.plan_writer = plan_writer
        self._lock = threading.Lock()
        self._threads = {}
        self._leases = {}
        self._cancellations = set()
        self._closing = threading.Event()

    def _source(self, command, deadline):
        if command.operation != "stage_transcode":
            raise MediaArchiveActionWorkerError("worker_unavailable")
        source = self.resolver.resolve(command, deadline=deadline)
        target = command.target
        if (type(source) is not ResolvedArchiveActionSource
                or not hmac.compare_digest(source.commandDigest, action_command_digest(command))
                or (source.sourceItemId, source.mediaKey, source.sourceSizeBytes,
                    source.sourceCodec, source.durationSeconds)
                != (target.sourceItemId, target.mediaKey, target.sourceSizeBytes,
                    target.sourceCodec, target.durationSeconds)
                or type(source.libraryId) is not int or source.libraryId < 1
                or not Path(source.path).is_absolute()
                or time.monotonic() >= deadline):
            raise MediaArchiveActionWorkerError("evidence_changed")
        return source

    def _cleanup_source(self, command, deadline, *, preview):
        if (command.operation != "cleanup_retained_original"
                or command.target.targetType != "retained_original"):
            raise MediaArchiveActionWorkerError("worker_unavailable")
        with self.journal.locked():
            source = self.journal.get(command.target.sourceOperationId)
            if (source is None or source.state != "succeeded"
                    or source.receipt is None
                    or source.command.operation != "stage_transcode"
                    or source.command.target.targetType != "transcode"
                    or source.command.candidate != command.candidate
                    or source.receipt.retainedOriginal is not True
                    or source.receipt.proofDigest != self.journal.proof_digest(
                        source.command, source.evidence)):
                raise MediaArchiveActionWorkerError("evidence_changed")
        evidence = source.evidence
        if (evidence.retainedDigest is None
                or evidence.retainedBytes is None
                or evidence.outputDigest is None
                or evidence.outputBytes is None
                or evidence.outputCodec != source.command.target.targetCodec
                or not evidence.outputVerified
                or not evidence.outputInstalled):
            raise MediaArchiveActionWorkerError("evidence_changed")
        staged = self.files.lookup(source.command)
        if (staged.commandDigest != source.command_digest
                or staged.source.sha256 != evidence.retainedDigest
                or staged.source.byteLength != evidence.retainedBytes):
            raise MediaArchiveActionWorkerError("evidence_changed")
        if self.resolver.authorize_retained(
                command, source.command, staged.source.path,
                deadline=deadline) is not True:
            raise MediaArchiveActionWorkerError("authority_changed")
        if preview:
            self.files.preview_retained_cleanup(
                staged, output_bytes=evidence.outputBytes)
        if time.monotonic() >= deadline:
            raise MediaArchiveActionWorkerError("authority_changed")
        return source, staged

    @staticmethod
    def _receipt(command, state, *, retained=False, error=None, proof=None):
        return ArchiveActionWorkerReceipt(
            operationId=command.operationId, evidenceDigest=command.evidenceDigest,
            state=state, errorCode=error, retainedOriginal=retained,
            proofDigest=proof,
        )

    def _stop_code(self, operation):
        with self._lock:
            if operation in self._cancellations or self._closing.is_set():
                return "cancelled"
            if self._leases.get(operation, 0) <= time.monotonic():
                return "authority_changed"
        return None

    def _require_lease(self, operation):
        code = self._stop_code(operation)
        if code is not None:
            raise MediaArchiveActionWorkerError(code)

    def preview(self, command, *, deadline, gate):
        if not gate():
            raise MediaArchiveActionWorkerError("authority_changed")
        if command.operation == "cleanup_retained_original":
            self._cleanup_source(command, deadline, preview=True)
            if not gate() or time.monotonic() >= deadline:
                raise MediaArchiveActionWorkerError("authority_changed")
            return ArchiveActionWorkerPreview(
                operationId=command.operationId,
                evidenceDigest=command.evidenceDigest,
                state="ready", requiredBytes=0,
                originalWillBeRetained=False,
            )
        source = self._source(command, deadline)
        # Preview is read-only and bounded. Full hash/copy follows confirmation.
        with self.files._library_parent(source.path) as (parent, name):
            import os
            import stat
            info = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if not stat.S_ISREG(info.st_mode) or info.st_size != source.sourceSizeBytes:
                raise MediaArchiveActionWorkerError("evidence_changed")
        if (not gate() or time.monotonic() >= deadline
                or self.files.retained_bytes() + source.sourceSizeBytes > self.files.quota_bytes):
            raise MediaArchiveActionWorkerError("worker_unavailable")
        return ArchiveActionWorkerPreview(
            operationId=command.operationId, evidenceDigest=command.evidenceDigest,
            state="ready", requiredBytes=command.reservedBytes,
            originalWillBeRetained=True,
        )

    def _renew(self, command, cancelled):
        with self._lock:
            self._leases[command.operationId] = time.monotonic() + self.LEASE_SECONDS
            if cancelled():
                self._cancellations.add(command.operationId)
            return command.operationId in self._threads

    def execute(self, command, *, deadline, cancelled):
        if self._closing.is_set() or time.monotonic() >= deadline:
            raise MediaArchiveActionWorkerError("worker_unavailable")
        with self.journal.locked():
            record = self.journal.get(command.operationId)
            if (record is not None
                    and record.command_digest != action_command_digest(command)):
                raise MediaArchiveActionWorkerError("evidence_changed")
            if (record is not None and record.receipt is not None
                    and record.state in {
                        "succeeded", "failed", "cancelled",
                        "needs_attention"}):
                return record.receipt
        if record is None:
            if command.operation == "stage_transcode":
                self._source(command, deadline)
            elif command.operation == "cleanup_retained_original":
                self._cleanup_source(command, deadline, preview=True)
            else:
                raise MediaArchiveActionWorkerError("worker_unavailable")
            with self.journal.locked():
                record = self.journal.get(command.operationId)
                if record is None:
                    record = self.journal.prepare(command)
                elif record.command_digest != action_command_digest(command):
                    raise MediaArchiveActionWorkerError("evidence_changed")
                elif record.receipt is not None and record.state in {
                        "succeeded", "failed", "cancelled",
                        "needs_attention"}:
                    return record.receipt
        self._renew(command, cancelled)
        self._launch(command)
        return self._receipt(command, "running")

    def reconcile(self, command, *, deadline, cancelled):
        # Cancellation and lease renewal remain responsive during long copies.
        running = self._renew(command, cancelled)
        if running:
            return self._receipt(command, "running")
        with self.journal.locked():
            record = self.journal.get(command.operationId)
            if record is None or record.command_digest != action_command_digest(command):
                raise MediaArchiveActionWorkerError("evidence_changed")
            if record.receipt is not None and record.state in {"succeeded", "failed", "cancelled"}:
                return record.receipt
            if record.state == "needs_attention" and not self._recovery_ready(command, record):
                return record.receipt
        self._launch(command)
        return self._receipt(command, "running")

    def _recovery_ready(self, command, record):
        # An unknown submission cannot be made certain by polling or repeating
        # it. Resume only from independently recorded terminal/install evidence.
        evidence = record.evidence
        if command.operation == "cleanup_retained_original":
            return (evidence.cleanupDeleteIntent
                    and not evidence.cancelRequested
                    and record.receipt.errorCode in {
                        "effect_unknown", "authority_changed"}
                    and not self._closing.is_set())
        if (evidence.cancelRequested or evidence.providerTaskId is None
                or record.receipt.errorCode not in {"effect_unknown", "authority_changed"}
                or self._closing.is_set()):
            return False
        if evidence.installIntent:
            return True
        staged = self.files.lookup(command)
        return self.terminals.lookup_terminal(evidence.providerTaskId, staged.workPath) is not None

    def _launch(self, command):
        with self._lock:
            if command.operationId in self._threads:
                return
            if self._threads or self._closing.is_set():
                raise MediaArchiveActionWorkerError("worker_unavailable")
            thread = threading.Thread(target=self._run, args=(command,), daemon=True)
            self._threads[command.operationId] = thread
            thread.start()

    def _save(self, command, state, evidence, *, error=None):
        with self.journal.locked():
            record = self.journal.get(command.operationId)
            if record.state in {"succeeded", "failed", "cancelled"}:
                return record
            retained = command.operation == "stage_transcode" and evidence.retainedDigest is not None
            receipt = self._receipt(
                command, state, retained=retained if state != "running" else False,
                error=error,
                proof=self.journal.proof_digest(command, evidence) if state == "succeeded" else None,
            )
            return self.journal.transition(record, state, evidence=evidence, receipt=receipt)

    def _advance_evidence(self, command, **changes):
        with self.journal.locked():
            record = self.journal.get(command.operationId)
            evidence = ArchiveActionEffectEvidence.model_validate({
                **record.evidence.model_dump(mode="python"), **changes,
            })
            state = "running" if record.state == "uncertain" else record.state
            receipt = self._receipt(command, "running") if state == "running" else None
            return self.journal.transition(record, state, evidence=evidence, receipt=receipt)

    def _run(self, command):
        try:
            with self.journal.locked():
                record = self.journal.get(command.operationId)
                if record.state == "prepared":
                    record = self.journal.begin(record)
                    fresh = True
                else:
                    fresh = False
            if command.operation == "cleanup_retained_original":
                self._run_retained_cleanup(command, record)
                return
            if command.operation != "stage_transcode":
                raise MediaArchiveActionWorkerError("worker_unavailable")
            self._require_lease(command.operationId)
            if fresh:
                source = self._source(command, time.monotonic() + 5)
                stop = lambda: self._stop_code(command.operationId) is not None
                # Protect the shared quota throughout copying and stage metadata.
                with self.journal.locked():
                    observed = self.files.observe_source(
                        source.path, expected_bytes=source.sourceSizeBytes, cancelled=stop)
                    record = self.journal.get(command.operationId)
                    evidence = ArchiveActionEffectEvidence(
                        sourceDigest=observed.sha256, sourceBytes=observed.byteLength)
                    record = self.journal.transition(record, "mutating", evidence=evidence)
                    staged = self.files.retain_and_stage(command, observed, cancelled=stop)
                    evidence = ArchiveActionEffectEvidence(
                        **evidence.model_dump(exclude={"retainedDigest", "retainedBytes", "workDigest"}),
                        retainedDigest=observed.sha256, retainedBytes=observed.byteLength,
                        workDigest=observed.sha256,
                    )
                    record = self.journal.transition(record, "mutating", evidence=evidence)
                self._require_lease(command.operationId)
                if self.plan_writer is not None:
                    self.plan_writer(
                        command, staged, deadline=time.monotonic() + 5)
                self._require_lease(command.operationId)
                decision = self.unmanic.test_path(staged.workPath, library_id=source.libraryId)
                if decision.shouldQueue is not True or decision.issueCount != 0:
                    raise MediaArchiveActionWorkerError("verification_failed")
                self._require_lease(command.operationId)
                # `mutating` is already durable. A lost create acknowledgement is
                # reconciled as unknown; there is no second provider submission.
                with self.journal.locked():
                    record = self.journal.get(command.operationId)
                    record = self.journal.transition(record, "uncertain")
                task = self.unmanic.create_local_task(staged.workPath, library_id=source.libraryId)
                if task.path != staged.workPath or task.libraryId != source.libraryId:
                    raise MediaArchiveActionWorkerError("effect_unknown")
                record = self._advance_evidence(command, providerTaskId=task.id)
                record = self._save(command, "running", record.evidence)
            else:
                staged = self.files.lookup(command)
                if record.evidence.providerTaskId is None:
                    raise MediaArchiveActionWorkerError("effect_unknown")
                if record.evidence.installIntent:
                    if self.resolver.authorize(command, deadline=time.monotonic()+5) is not True:
                        raise MediaArchiveActionWorkerError("authority_changed")
                    self.files.inspect_original(staged)
                    installed = self.files.observe_source(
                        staged.source.path, expected_bytes=record.evidence.outputBytes)
                    if installed.sha256 == record.evidence.outputDigest:
                        record = self._advance_evidence(command, outputInstalled=True)
                        self._save(command, "succeeded", record.evidence)
                        return
                    raise MediaArchiveActionWorkerError("effect_unknown")
                source = self._source(command, time.monotonic() + 5)
            terminal_deadline = time.monotonic() + self.verifier.MAX_SECONDS
            while True:
                self._require_lease(command.operationId)
                terminal = self.terminals.lookup_terminal(record.evidence.providerTaskId, staged.workPath)
                if terminal is not None:
                    break
                if time.monotonic() >= terminal_deadline:
                    raise MediaArchiveActionWorkerError("effect_unknown")
                self._closing.wait(0.2)
            if (terminal.libraryId != source.libraryId
                    or terminal.destinationPath != staged.workPath
                    or terminal.destinationFiles != (staged.workPath,)):
                raise MediaArchiveActionWorkerError("verification_failed")
            record = self._advance_evidence(command, providerTerminal=terminal.terminal)
            if terminal.terminal != "succeeded":
                self._save(command, "failed", record.evidence, error="verification_failed")
                return
            self._require_lease(command.operationId)
            self._source(command, time.monotonic() + 5)
            verified = self.verifier.verify(
                command, staged.retainedPath, staged.workPath,
                deadline=time.monotonic()+self.verifier.MAX_SECONDS,
                cancelled=lambda: self._stop_code(command.operationId) is not None)
            record = self._advance_evidence(
                command, outputDigest=verified.digest, outputBytes=verified.byteLength,
                outputCodec=verified.codec, outputVerified=True)

            with self.journal.locked():
                record = self.journal.get(command.operationId)

                def before_replace(*_args):
                    nonlocal record
                    self._require_lease(command.operationId)
                    evidence = ArchiveActionEffectEvidence.model_validate({
                        **record.evidence.model_dump(mode="python"), "installIntent": True})
                    receipt = self._receipt(command, "running") if record.state == "running" else None
                    record = self.journal.transition(record, record.state, evidence=evidence, receipt=receipt)

                self.files.install_verified(
                    staged, output_digest=verified.digest, output_bytes=verified.byteLength,
                    before_replace=before_replace,
                    cancelled=lambda: self._stop_code(command.operationId) is not None)
                evidence = ArchiveActionEffectEvidence.model_validate({
                    **record.evidence.model_dump(mode="python"), "outputInstalled": True})
                receipt = self._receipt(command, "succeeded", retained=True,
                    proof=self.journal.proof_digest(command, evidence))
                self.journal.transition(record, "succeeded", evidence=evidence, receipt=receipt)
        except Exception as error:
            self._failure(command, error)
        finally:
            with self._lock:
                self._threads.pop(command.operationId, None)

    @staticmethod
    def _cleanup_proof(evidence, source):
        return ArchiveRetainedCleanupProof(
            operationId=source.command.operationId,
            commandDigest=source.command_digest,
            retainedDevice=evidence.cleanupRetainedDevice,
            retainedInode=evidence.cleanupRetainedInode,
            retainedDigest=evidence.cleanupRetainedDigest,
            retainedBytes=evidence.cleanupRetainedBytes,
            outputDigest=evidence.cleanupOutputDigest,
            outputBytes=evidence.cleanupOutputBytes,
        )

    def _run_retained_cleanup(self, command, record):
        self._require_lease(command.operationId)
        source, staged = self._cleanup_source(
            command, time.monotonic() + 5, preview=False)
        evidence = record.evidence
        stop = lambda: self._stop_code(command.operationId) is not None

        def before_unlink(_proof):
            self._require_lease(command.operationId)
            if self.resolver.authorize_retained(
                    command, source.command, staged.source.path,
                    deadline=time.monotonic() + 5) is not True:
                raise MediaArchiveActionWorkerError("authority_changed")

        if evidence.cleanupDeleteIntent:
            if (evidence.cleanupSourceProofDigest
                    != source.receipt.proofDigest
                    or evidence.cleanupRetainedDigest
                    != source.evidence.retainedDigest
                    or evidence.cleanupRetainedBytes
                    != source.evidence.retainedBytes
                    or evidence.cleanupOutputDigest
                    != source.evidence.outputDigest
                    or evidence.cleanupOutputBytes
                    != source.evidence.outputBytes):
                raise MediaArchiveActionWorkerError("evidence_changed")
            proof = self._cleanup_proof(evidence, source)
            self.files.cleanup_retained(
                staged, proof, intent_recorded=True,
                before_unlink=before_unlink, cancelled=stop)
        else:
            proof = self.files.observe_retained_cleanup(
                staged,
                expected_digest=source.evidence.retainedDigest,
                output_digest=source.evidence.outputDigest,
                output_bytes=source.evidence.outputBytes,
                cancelled=stop)

            def before_delete(observed):
                nonlocal record, evidence
                self._require_lease(command.operationId)
                if observed != proof:
                    raise MediaArchiveActionWorkerError("evidence_changed")
                evidence = ArchiveActionEffectEvidence.model_validate({
                    **record.evidence.model_dump(mode="python"),
                    "cleanupSourceProofDigest": source.receipt.proofDigest,
                    "cleanupRetainedDevice": proof.retainedDevice,
                    "cleanupRetainedInode": proof.retainedInode,
                    "cleanupRetainedDigest": proof.retainedDigest,
                    "cleanupRetainedBytes": proof.retainedBytes,
                    "cleanupOutputDigest": proof.outputDigest,
                    "cleanupOutputBytes": proof.outputBytes,
                    "cleanupDeleteIntent": True,
                })
                with self.journal.locked():
                    current = self.journal.get(command.operationId)
                    record = self.journal.transition(
                        current, current.state, evidence=evidence)

            self.files.cleanup_retained(
                staged, proof, intent_recorded=False,
                before_delete=before_delete, before_unlink=before_unlink,
                cancelled=stop)
        self._require_lease(command.operationId)
        record = self._advance_evidence(command, cleanupVerified=True)
        self._save(command, "succeeded", record.evidence)

    def _failure(self, command, error):
        try:
            with self.journal.locked():
                record = self.journal.get(command.operationId)
                if record.state in {"succeeded", "failed", "cancelled"}:
                    return
            stop = self._stop_code(command.operationId)
            evidence = record.evidence
            if stop == "cancelled":
                evidence = ArchiveActionEffectEvidence.model_validate({
                    **evidence.model_dump(mode="python"), "cancelRequested": True})
                if (record.state != "uncertain" and evidence.providerTaskId is None
                        and not evidence.installIntent
                        and not evidence.cleanupDeleteIntent):
                    self._save(command, "cancelled", evidence)
                else:
                    self._save(command, "needs_attention", evidence, error="cancel_unknown")
            elif stop == "authority_changed":
                self._save(command, "needs_attention", evidence, error="authority_changed")
            elif isinstance(error, ArchiveVerificationError) and not evidence.installIntent:
                self._save(command, "failed", evidence, error="verification_failed")
            else:
                code = getattr(error, "code", None)
                code = code if code in {"evidence_changed", "verification_failed", "effect_unknown"} else "effect_unknown"
                self._save(command, "needs_attention", evidence, error=code)
        except (ArchiveActionJournalError, ArchiveFileStoreError, ValueError):
            # Corrupt storage never becomes a fabricated receipt.
            pass

    def close(self):
        self._closing.set()
        with self._lock:
            threads = tuple(self._threads.values())
        for thread in threads:
            thread.join(timeout=5)
