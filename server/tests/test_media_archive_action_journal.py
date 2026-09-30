"""Crash/replay and durable evidence tests for the worker-owned F30 journal."""

import os
import sqlite3

import pytest

from larenor_server.media_archive_actions.journal import (
    ArchiveActionEffectEvidence,
    ArchiveActionJournalError,
    MediaArchiveActionJournal,
)
from larenor_server.media_archive_actions.models import (
    ArchiveActionWorkerReceipt,
    PrivateArchiveActionCommand,
)


def command():
    return PrivateArchiveActionCommand.model_validate({
        "operationId": "1" * 32,
        "operation": "stage_transcode",
        "authority": {
            "installationId": "2" * 32, "installationRevision": 4,
            "snapshotRevision": 9, "sourceRevisions": {
                "jellyfin": 3, "sonarr": 5, "radarr": 6, "qbittorrent": 7,
            },
        },
        "candidate": {
            "candidateId": "b" * 64, "kind": "transcode", "title": "Archive item",
            "potentialBytes": 1024, "confidence": "medium",
            "comparison": {
                "basis": "bounded_transcode_estimate", "observedBytes": 4096,
                "estimatedRetainedBytes": 3072, "estimatedSavingBytes": 1024,
            },
            "evidence": ["source_profile_verified", "target_playback_verified", "bounded_size_estimate"],
            "actionType": "optimize",
        },
        "target": {
            "targetType": "transcode", "sourceItemId": "3" * 32, "mediaKey": "movie:tmdb:42",
            "sourceCodec": "h264", "targetCodec": "hevc", "sourceBitrate": 12288,
            "targetBitrate": 4096, "durationSeconds": 1, "sourceSizeBytes": 4096,
            "targetPlaybackVerified": True,
        },
        "evidenceDigest": "a" * 64, "reservedBytes": 4096, "retainOriginal": True,
    })


@pytest.fixture
def directory(tmp_path):
    value = tmp_path / "journal"
    value.mkdir(mode=0o700)
    return value


def running(cmd):
    return ArchiveActionWorkerReceipt(operationId=cmd.operationId,
        evidenceDigest=cmd.evidenceDigest, state="running", errorCode=None,
        retainedOriginal=False)


def successful_evidence():
    return ArchiveActionEffectEvidence(
        sourceDigest="c" * 64, sourceBytes=4096,
        retainedDigest="c" * 64, retainedBytes=4096, workDigest="c" * 64,
        providerTaskId=42, providerTerminal="succeeded", outputDigest="d" * 64,
        outputBytes=3000, outputCodec="hevc", outputVerified=True,
        installIntent=True, outputInstalled=True,
    )


def cleanup_command(source=None):
    source = source or command()
    return PrivateArchiveActionCommand(
        operationId="9" * 32,
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


def test_durable_begin_survives_restart_and_exact_replay(directory):
    cmd = command()
    with MediaArchiveActionJournal(directory) as journal:
        with journal.locked():
            prepared = journal.prepare(cmd)
            started = journal.begin(prepared)
            assert started.state == "mutating" and started.revision == 2
    with MediaArchiveActionJournal(directory) as journal:
        with journal.locked():
            replay = journal.prepare(cmd)
            assert replay.state == "mutating" and replay.revision == 2
            assert len(journal.records()) == 1
            with pytest.raises(ArchiveActionJournalError, match="invalid_action_transition"):
                journal.begin(replay)


def test_same_operation_different_full_command_cannot_replay(directory):
    cmd = command()
    with MediaArchiveActionJournal(directory) as journal:
        with journal.locked():
            journal.prepare(cmd)
            changed = cmd.model_dump(mode="json")
            changed["authority"]["installationRevision"] += 1
            with pytest.raises(ArchiveActionJournalError, match="idempotency_conflict"):
                journal.prepare(PrivateArchiveActionCommand.model_validate(changed))


def test_terminal_proof_requires_verified_original_and_installed_smaller_output(directory):
    cmd = command()
    with MediaArchiveActionJournal(directory) as journal:
        with journal.locked():
            started = journal.begin(journal.prepare(cmd))
            evidence = successful_evidence()
            receipt = ArchiveActionWorkerReceipt(operationId=cmd.operationId,
                evidenceDigest=cmd.evidenceDigest, state="succeeded", errorCode=None,
                retainedOriginal=True, proofDigest=journal.proof_digest(cmd, evidence))
            complete = journal.transition(started, "succeeded", evidence=evidence, receipt=receipt)
            assert complete.receipt == receipt
    with MediaArchiveActionJournal(directory) as journal:
        with journal.locked():
            complete = journal.prepare(cmd)
            assert complete.receipt == receipt
            with pytest.raises(ArchiveActionJournalError, match="invalid_action_transition"):
                journal.transition(complete, "running", receipt=running(cmd))


def test_provider_task_success_alone_is_not_output_proof(directory):
    cmd = command()
    evidence = ArchiveActionEffectEvidence(providerTaskId=42, providerTerminal="succeeded")
    with MediaArchiveActionJournal(directory) as journal:
        with journal.locked():
            started = journal.begin(journal.prepare(cmd))
            receipt = ArchiveActionWorkerReceipt(operationId=cmd.operationId,
                evidenceDigest=cmd.evidenceDigest, state="succeeded", errorCode=None,
                retainedOriginal=True, proofDigest=journal.proof_digest(cmd, evidence))
            with pytest.raises(ArchiveActionJournalError):
                journal.transition(started, "succeeded", evidence=evidence, receipt=receipt)
            assert journal.get(cmd.operationId).state == "mutating"


def test_stale_cas_and_confirmed_original_cannot_be_lost(directory):
    cmd = command()
    with MediaArchiveActionJournal(directory) as journal:
        with journal.locked():
            started = journal.begin(journal.prepare(cmd))
            evidence = ArchiveActionEffectEvidence(sourceDigest="c" * 64, sourceBytes=4096,
                retainedDigest="c" * 64, retainedBytes=4096)
            active = journal.transition(started, "running", evidence=evidence, receipt=running(cmd))
            with pytest.raises(ArchiveActionJournalError, match="action_journal_changed"):
                journal.transition(started, "uncertain")
            with pytest.raises(ArchiveActionJournalError, match="evidence_changed"):
                journal.transition(active, "uncertain", evidence=ArchiveActionEffectEvidence())
            recovered = journal.transition(active, "uncertain")
            assert recovered.evidence.retainedBytes == 4096


def test_cleanup_delete_intent_and_exact_identity_survive_restart(directory):
    source = command()
    cleanup = cleanup_command(source)
    source_evidence = successful_evidence()
    with MediaArchiveActionJournal(directory) as journal:
        with journal.locked():
            started = journal.begin(journal.prepare(source))
            source_receipt = ArchiveActionWorkerReceipt(
                operationId=source.operationId,
                evidenceDigest=source.evidenceDigest,
                state="succeeded", errorCode=None, retainedOriginal=True,
                proofDigest=journal.proof_digest(source, source_evidence),
            )
            journal.transition(
                started, "succeeded", evidence=source_evidence,
                receipt=source_receipt)
            cleanup_record = journal.begin(journal.prepare(cleanup))
            unowned = ArchiveActionEffectEvidence(cleanupVerified=True)
            unowned_receipt = ArchiveActionWorkerReceipt(
                operationId=cleanup.operationId,
                evidenceDigest=cleanup.evidenceDigest,
                state="succeeded", errorCode=None,
                retainedOriginal=False,
                proofDigest=journal.proof_digest(cleanup, unowned),
            )
            with pytest.raises(ArchiveActionJournalError):
                journal.transition(
                    cleanup_record, "succeeded", evidence=unowned,
                    receipt=unowned_receipt)
            intent = ArchiveActionEffectEvidence(
                cleanupSourceProofDigest=source_receipt.proofDigest,
                cleanupRetainedDevice=11,
                cleanupRetainedInode=12,
                cleanupRetainedDigest=source_evidence.retainedDigest,
                cleanupRetainedBytes=source_evidence.retainedBytes,
                cleanupOutputDigest=source_evidence.outputDigest,
                cleanupOutputBytes=source_evidence.outputBytes,
                cleanupDeleteIntent=True,
            )
            attention = ArchiveActionWorkerReceipt(
                operationId=cleanup.operationId,
                evidenceDigest=cleanup.evidenceDigest,
                state="needs_attention", errorCode="effect_unknown",
                retainedOriginal=False,
            )
            journal.transition(
                cleanup_record, "needs_attention", evidence=intent,
                receipt=attention)

    with MediaArchiveActionJournal(directory) as journal:
        with journal.locked():
            recovered = journal.get(cleanup.operationId)
            assert recovered.evidence == intent
            running_record = journal.transition(
                recovered, "running", evidence=intent,
                receipt=running(cleanup))
            verified = intent.model_copy(update={"cleanupVerified": True})
            receipt = ArchiveActionWorkerReceipt(
                operationId=cleanup.operationId,
                evidenceDigest=cleanup.evidenceDigest,
                state="succeeded", errorCode=None,
                retainedOriginal=False,
                proofDigest=journal.proof_digest(cleanup, verified),
            )
            finished = journal.transition(
                running_record, "succeeded", evidence=verified,
                receipt=receipt)
            assert finished.evidence.cleanupVerified

    with pytest.raises(ValueError):
        ArchiveActionEffectEvidence(cleanupRetainedDevice=11)


@pytest.mark.parametrize("tamper", [
    "DELETE FROM operations",
    "UPDATE operations SET revision=revision+1",
    "UPDATE operations SET payload=x'7b7d'",
    "UPDATE metadata SET count=0",
    "CREATE TABLE injected(value TEXT)",
])
def test_corrupt_rows_schema_or_deleted_receipt_fail_closed(directory, tamper):
    with MediaArchiveActionJournal(directory) as journal:
        with journal.locked():
            journal.begin(journal.prepare(command()))
    db = sqlite3.connect(directory / "media-archive-actions.sqlite")
    db.execute(tamper)
    db.commit()
    db.close()
    with pytest.raises(ArchiveActionJournalError, match="action_journal_unavailable"):
        MediaArchiveActionJournal(directory)


def test_nonprivate_and_symlink_paths_are_rejected(directory, tmp_path):
    os.chmod(directory, 0o755)
    with pytest.raises(ArchiveActionJournalError):
        MediaArchiveActionJournal(directory)
    os.chmod(directory, 0o700)
    with MediaArchiveActionJournal(directory):
        pass
    database = directory / "media-archive-actions.sqlite"
    moved = directory / "moved.sqlite"
    database.rename(moved)
    database.symlink_to(moved)
    with pytest.raises(ArchiveActionJournalError):
        MediaArchiveActionJournal(directory)


def test_two_process_handles_cannot_hold_one_effect_lease(directory):
    with MediaArchiveActionJournal(directory) as first, MediaArchiveActionJournal(directory) as second:
        with first.locked():
            with pytest.raises(ArchiveActionJournalError):
                with second.locked():
                    pytest.fail("a second effect lease must not be acquired")
        with second.locked():
            assert second.prepare(command()).state == "prepared"
